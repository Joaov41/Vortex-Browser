import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../Browser/background-media.js', import.meta.url), 'utf8');
function fixture(host = 'www.youtube.com') {
    const context = vm.createContext({console});
    vm.runInContext(`
        let clock = 0;
        const performance = {now: () => clock};
        class Events {
            listeners = new Map();
            addEventListener(name, fn) {
                if (!this.listeners.has(name)) this.listeners.set(name, []);
                this.listeners.get(name).push(fn);
            }
            emit(name, target = this, extra = {}) {
                for (const fn of this.listeners.get(name) || []) fn({type: name, target, ...extra});
            }
        }
        class Document extends Events {
            actualState = 'visible';
            media = [];
            get visibilityState() { return this.actualState; }
            get hidden() { return this.actualState !== 'visible'; }
            querySelectorAll() { return this.media; }
        }
        const document = new Document();
        const window = new Events();
        let appResumeRequests = 0;
        window.webkit = {messageHandlers: {vortexMediaResume: {postMessage() {appResumeRequests++;}}}};
        const location = {hostname: ${JSON.stringify(host)}};
        const navigator = {
            audioSession: {type: 'auto'},
            mediaSession: {handlers: {}, setActionHandler(action, fn) {this.handlers[action] = fn;}}
        };
        class HTMLMediaElement {
            paused = true;
            ended = false;
            playCount = 0;
            denyPlay = false;
            denialName = 'NotAllowedError';
            play() {
                this.playCount++;
                if (this.denyPlay) {const error = new Error('Denied'); error.name = this.denialName; return Promise.reject(error);}
                this.paused = false;
                document.emit('play', this);
                document.emit('playing', this);
                return Promise.resolve();
            }
            pause() {
                if (!this.paused) {this.paused = true; document.emit('pause', this);}
            }
        }
        const platformPause = HTMLMediaElement.prototype.pause;
        function addMedia() { const media = new HTMLMediaElement(); document.media.push(media); return media; }
        const video = addMedia();
        function visibility(value) {document.actualState = value; window.emit('visibilitychange', document);}
        function advance(ms) {clock += ms;}
    `, context);
    vm.runInContext(source, context);
    return code => vm.runInContext(code, context);
}
function test(name, run) { run(); console.log('PASS ' + name); }

test('Native pause before hidden resumes once on the transition', () => {
    const f = fixture();
    f('__vortexBackgroundMedia.setEnabled(true); video.play(); advance(1000); platformPause.call(video)');
    assert.equal(f('video.paused'), true);
    f("visibility('hidden')");
    assert.equal(f('video.paused'), false);
    assert.equal(f('video.playCount'), 2);
    f('platformPause.call(video)');
    assert.equal(f('video.paused'), true, 'A second pause must not be fought');
});
test('Native pause just after hidden resumes once', () => {
    const f = fixture();
    f("__vortexBackgroundMedia.setEnabled(true); video.play(); visibility('hidden'); platformPause.call(video)");
    assert.equal(f('video.paused'), false);
    assert.equal(f('video.playCount'), 2);
});
test('Explicit pause followed immediately by locking stays paused', () => {
    const f = fixture();
    f("__vortexBackgroundMedia.setEnabled(true); video.play(); video.pause(); visibility('hidden')");
    assert.equal(f('video.playCount'), 1);
    assert.equal(f('video.paused'), true);
});
test('Touch on native controls followed by backgrounding stays paused', () => {
    const f = fixture();
    f("__vortexBackgroundMedia.setEnabled(true); video.play(); document.emit('touchend', video, {isTrusted: true}); platformPause.call(video); visibility('hidden')");
    assert.equal(f('video.playCount'), 1);
});
test('Remote Media Session pause stays paused during the transition', () => {
    const f = fixture();
    f("__vortexBackgroundMedia.setEnabled(true); video.play(); navigator.mediaSession.setActionHandler('pause', () => platformPause.call(video)); visibility('hidden'); navigator.mediaSession.handlers.pause()");
    assert.equal(f('video.paused'), true);
    assert.equal(f('video.playCount'), 1);
});
test('Pause after the transition window does not resume', () => {
    const f = fixture();
    f("__vortexBackgroundMedia.setEnabled(true); video.play(); visibility('hidden'); advance(3000); platformPause.call(video)");
    assert.equal(f('video.playCount'), 1);
});
test('An old foreground pause is not revived on backgrounding', () => {
    const f = fixture();
    f("__vortexBackgroundMedia.setEnabled(true); video.play(); platformPause.call(video); advance(3000); visibility('hidden')");
    assert.equal(f('video.playCount'), 1);
});
test('Ended and never-played videos are not started', () => {
    const f = fixture();
    f("__vortexBackgroundMedia.setEnabled(true); visibility('hidden')");
    assert.equal(f('video.playCount'), 0);
    f("visibility('visible'); video.play(); video.ended = true; document.emit('ended', video); platformPause.call(video); visibility('hidden')");
    assert.equal(f('video.playCount'), 1);
});
test('Disabled feature retains actual visibility and does not restart playback', () => {
    const f = fixture();
    f("video.play(); platformPause.call(video); visibility('hidden')");
    assert.equal(f('document.visibilityState'), 'hidden');
    assert.equal(f('document.hidden'), true);
    assert.equal(f('video.playCount'), 1);
});
test('Disabling while a transition is pending cancels recovery', () => {
    const f = fixture();
    f("__vortexBackgroundMedia.setEnabled(true); video.play(); platformPause.call(video); __vortexBackgroundMedia.setEnabled(false); visibility('hidden')");
    assert.equal(f('video.playCount'), 1);
    assert.equal(f('navigator.audioSession.type'), 'auto');
});
test('YouTube sees visible while the transition handler sees the true state', () => {
    const f = fixture();
    f("__vortexBackgroundMedia.setEnabled(true); video.play(); platformPause.call(video); visibility('hidden')");
    assert.equal(f('document.visibilityState'), 'visible');
    assert.equal(f('document.hidden'), false);
    assert.equal(f('video.playCount'), 2);
});
test('Unrelated and lookalike hosts retain normal visibility', () => {
    for (const host of ['example.com', 'youtube.com.attacker.example', 'notyoutube.com']) {
        const f = fixture(host);
        f("__vortexBackgroundMedia.setEnabled(true); visibility('hidden')");
        assert.equal(f('document.visibilityState'), 'hidden', host);
    }
});
test('Replacement video elements are observed without mutation polling', () => {
    const f = fixture();
    f("__vortexBackgroundMedia.setEnabled(true); const replacement = addMedia(); replacement.play(); platformPause.call(replacement); visibility('hidden')");
    assert.equal(f('replacement.playCount'), 2);
});
test('Closing/stopping a tab cancels its pending recovery', () => {
    const f = fixture();
    f("__vortexBackgroundMedia.setEnabled(true); video.play(); platformPause.call(video); __vortexBackgroundMedia.cancelAutomaticResume(); visibility('hidden')");
    assert.equal(f('video.playCount'), 1);
});
test('Repeat injection does not stack wrappers/listeners', () => {
    const f = fixture();
    const before = f('HTMLMediaElement.prototype.pause');
    f(source);
    assert.equal(f('HTMLMediaElement.prototype.pause'), before);
});
test('Native audio-session takeover and deactivation remain absent', () => {
    const swift = readFileSync(new URL('../Browser/Services/BrowserMediaPlaybackCoordinator.swift', import.meta.url), 'utf8');
    assert.doesNotMatch(swift, /AVAudioSession|setActive\(|setCategory\(/);
});
for (const cancellation of ['', 'video.pause()', '__vortexBackgroundMedia.cancelAutomaticResume()', "visibility('visible')", 'advance(3000)']) {
    const f = fixture();
    f("__vortexBackgroundMedia.setEnabled(true); video.play(); advance(1000); video.denyPlay = true; platformPause.call(video); visibility('hidden')");
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(f('appResumeRequests'), 1);
    if (cancellation) f(cancellation);
    f('video.denyPlay = false; __vortexBackgroundMedia.resumeAfterPermissionRejection()');
    assert.equal(f('video.playCount'), cancellation ? 2 : 3);
    f('__vortexBackgroundMedia.resumeAfterPermissionRejection()');
    assert.equal(f('video.playCount'), cancellation ? 2 : 3, 'App retry is consumed once');
    console.log('PASS Permission rejection app retry: ' + (cancellation || 'resumes previously playing element'));
}
{
    const f = fixture();
    f("__vortexBackgroundMedia.setEnabled(true); video.play(); video.denyPlay = true; video.denialName = 'AbortError'; platformPause.call(video); visibility('hidden')");
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(f('appResumeRequests'), 0);
    console.log('PASS Other playback errors do not request app resumption');
}
console.log('22 background-media regression checks passed. Physical WebKit transitions still require device validation.');
