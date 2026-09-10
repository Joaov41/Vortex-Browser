// Keep WebKit's existing media player and system controls. Recover at most once from a
// platform pause during a visible -> hidden transition; never run a replay timer/loop.
(() => {
    if (globalThis.__vortexBackgroundMedia) return;
    const visibility = Object.getOwnPropertyDescriptor(Document.prototype, 'visibilityState');
    const hidden = Object.getOwnPropertyDescriptor(Document.prototype, 'hidden');
    if (!visibility?.get || !hidden?.get) return;
    const actualVisibility = () => visibility.get.call(document);
    const nativePlay = HTMLMediaElement.prototype.play;
    const nativePause = HTMLMediaElement.prototype.pause;
    const mediaState = new WeakMap();
    const now = () => performance.now();
    const transitionWindow = 2000;
    let enabled = false;
    let previousVisibility = actualVisibility();
    let lastUserInput = -Infinity;
    let savedAudioSessionType;
    let pendingNativeResume = null;
    const isYouTube = ['youtube.com', 'youtube-nocookie.com'].some(domain =>
        location.hostname === domain || location.hostname.endsWith('.' + domain));

    function stateFor(media) {
        let state = mediaState.get(media);
        if (!state) {
            state = { playing: !media.paused && !media.ended, explicitPause: false,
                      pendingPause: null, resumeUntil: -Infinity, attempted: false };
            mediaState.set(media, state);
        }
        return state;
    }
    function cancel(media) {
        const state = stateFor(media);
        state.explicitPause = true;
        state.pendingPause = null;
        state.resumeUntil = -Infinity;
        if (pendingNativeResume === media) pendingNativeResume = null;
    }
    function trace(event, media, error) {
        if (typeof globalThis.__vortexMediaTrace !== 'function') return;
        const state = media ? stateFor(media) : null;
        try {
            globalThis.__vortexMediaTrace({event, time: media?.currentTime || 0,
                paused: media?.paused ?? true, visibility: actualVisibility(), enabled,
                explicit: state?.explicitPause ?? false, attempted: state?.attempted ?? false,
                inputAge: Math.min(now() - lastUserInput, 100000),
                mode: media?.webkitPresentationMode || '', error: error?.name || ''});
        } catch (_) {}
    }
    function resumeTransition(media, state) {
        if (!enabled || actualVisibility() === 'visible' || state.explicitPause ||
            state.attempted || now() > state.resumeUntil || media.ended || !media.paused) return;
        state.attempted = true;
        state.pendingPause = null;
        // The page may deny resumption. Do not keep trying or replace its player.
        trace('resume-attempt', media);
        try {
            Promise.resolve(nativePlay.call(media)).then(() => trace('resume-success', media), error => {
                trace('resume-rejected', media, error);
                // An app-initiated retry restores only this already-playing element; it does
                // not relax WebKit's autoplay policy for newly loaded pages or other media.
                if (error?.name !== 'NotAllowedError' || state.explicitPause ||
                    !enabled || now() > state.resumeUntil || actualVisibility() === 'visible') return;
                pendingNativeResume = media;
                try { window.webkit?.messageHandlers?.vortexMediaResume?.postMessage(null); } catch (_) {}
            });
        } catch (error) { trace('resume-rejected', media, error); }
    }
    function mediaEvent(event) {
        const media = event.target;
        if (!(media instanceof HTMLMediaElement)) return;
        const state = stateFor(media);
        trace(event.type, media);
        if (event.type === 'play' || event.type === 'playing') {
            state.playing = true;
            state.explicitPause = false;
            state.pendingPause = null;
            if (actualVisibility() === 'visible') state.attempted = false;
            if (enabled && navigator.audioSession) {
                try {
                    if (savedAudioSessionType === undefined) savedAudioSessionType = navigator.audioSession.type;
                    navigator.audioSession.type = 'playback';
                } catch (_) {}
            }
        } else if (event.type === 'ended' || event.type === 'emptied') {
            cancel(media);
            state.playing = false;
        } else if (event.type === 'pause') {
            const hadPlayback = state.playing;
            state.playing = false;
            if (!enabled || !hadPlayback || state.explicitPause || media.ended) return;
            // Native video controls can pause without calling the page's pause() method.
            if (now() - lastUserInput < 500) { cancel(media); return; }
            if (actualVisibility() === 'visible') state.pendingPause = now();
            else resumeTransition(media, state);
        }
    }
    function onVisibilityChange() {
        const current = actualVisibility();
        for (const media of document.querySelectorAll('video,audio')) {
            trace('visibility', media);
            const state = stateFor(media);
            if (current !== 'visible' && previousVisibility === 'visible') {
                const pausedForTransition = state.pendingPause !== null && now() - state.pendingPause <= transitionWindow;
                if (!state.explicitPause && ((!media.paused && !media.ended) || pausedForTransition)) {
                    state.resumeUntil = now() + transitionWindow;
                    state.attempted = false;
                    if (pausedForTransition) resumeTransition(media, state);
                }
                state.pendingPause = null;
            } else if (current === 'visible') {
                if (pendingNativeResume === media) pendingNativeResume = null;
                state.resumeUntil = -Infinity;
                state.pendingPause = null;
                state.attempted = false;
            }
        }
        previousVisibility = current;
    }

    // A page/user-requested pause is intentional, unlike WebKit's native background pause.
    HTMLMediaElement.prototype.pause = function(...args) {
        trace('page-pause-call', this);
        cancel(this);
        return Reflect.apply(nativePause, this, args);
    };
    for (const name of ['play', 'playing', 'pause', 'ended', 'emptied', 'webkitpresentationmodechanged']) {
        document.addEventListener(name, mediaEvent, true);
    }
    for (const name of ['pointerdown', 'touchend', 'keydown']) {
        document.addEventListener(name, event => { if (event.isTrusted) lastUserInput = now(); }, true);
    }
    window.addEventListener('visibilitychange', onVisibilityChange, true);
    // YouTube's page-level visibility handling otherwise stops the video as the app is hidden.
    // Other websites retain their original visibility API behavior.
    if (isYouTube) {
        Object.defineProperty(document, 'visibilityState', {
            configurable: true, get: () => enabled ? 'visible' : visibility.get.call(document)
        });
        Object.defineProperty(document, 'hidden', {
            configurable: true, get: () => enabled ? false : hidden.get.call(document)
        });
    }
    // Respect lock-screen pause callbacks registered by the website.
    if (navigator.mediaSession?.setActionHandler) {
        const setActionHandler = navigator.mediaSession.setActionHandler;
        navigator.mediaSession.setActionHandler = function(action, handler) {
            const wrapped = action === 'pause' && typeof handler === 'function' ? function(...args) {
                document.querySelectorAll('video,audio').forEach(cancel);
                return Reflect.apply(handler, this, args);
            } : handler;
            return Reflect.apply(setActionHandler, this, [action, wrapped]);
        };
    }
    globalThis.__vortexBackgroundMedia = {
        resumeAfterPermissionRejection() {
            const media = pendingNativeResume;
            pendingNativeResume = null;
            if (!media) return;
            const state = stateFor(media);
            if (!enabled || state.explicitPause || !state.attempted || !media.paused ||
                media.ended || actualVisibility() === 'visible' || now() > state.resumeUntil) return;
            trace('app-resume-attempt', media);
            try {
                Promise.resolve(nativePlay.call(media)).then(() => trace('app-resume-success', media), error => trace('app-resume-rejected', media, error));
            } catch (error) { trace('app-resume-rejected', media, error); }
        },
        setEnabled(value) {
            const next = value === true;
            if (next === enabled) return;
            enabled = next;
            trace('configuration');
            if (enabled && navigator.audioSession && [...document.querySelectorAll('video,audio')].some(m => !m.paused && !m.ended)) {
                try {
                    if (savedAudioSessionType === undefined) savedAudioSessionType = navigator.audioSession.type;
                    navigator.audioSession.type = 'playback';
                } catch (_) {}
            }
            if (!enabled) {
                pendingNativeResume = null;
                for (const media of document.querySelectorAll('video,audio')) {
                    const state = stateFor(media);
                    state.pendingPause = null;
                    state.resumeUntil = -Infinity;
                }
                if (savedAudioSessionType !== undefined && navigator.audioSession) {
                    try { navigator.audioSession.type = savedAudioSessionType; } catch (_) {}
                    savedAudioSessionType = undefined;
                }
            }
        },
        cancelAutomaticResume() { document.querySelectorAll('video,audio').forEach(cancel); }
    };
})();
