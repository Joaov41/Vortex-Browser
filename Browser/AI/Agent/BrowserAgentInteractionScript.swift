import Foundation

/// Shared with the manual distraction picker so persisted selectors use one algorithm.
enum BrowserStableSelectorScript {
    static let helpers = #"""
    const stableClass = c => /^[a-zA-Z][a-zA-Z_-]{1,40}$/.test(c);
    const stableID = id => /^[a-zA-Z][\w-]{0,60}$/.test(id) && !/\d{4,}/.test(id);

    function part(el) {
      if (el.id && stableID(el.id)) return "#" + CSS.escape(el.id);
      const classes = [...el.classList].filter(stableClass).slice(0, 2);
      return el.localName + classes.map(c => "." + CSS.escape(c)).join("");
    }

    function nthPart(el) {
      const base = part(el);
      if (base.startsWith("#") || !el.parentElement) return base;
      const same = [...el.parentElement.children].filter(c => c.localName === el.localName);
      return same.length > 1 ? base + ":nth-of-type(" + (same.indexOf(el) + 1) + ")" : base;
    }

    function uniquelyMatches(selector, el) {
      try {
        const matches = document.querySelectorAll(selector);
        return matches.length === 1 && matches[0] === el;
      } catch (e) { return false; }
    }

    function selectorFor(el) {
      let parts = [];
      for (let cur = el; cur && cur !== document.documentElement; cur = cur.parentElement) {
        const p = part(cur);
        parts.unshift(p);
        const selector = parts.join(" > ");
        if (uniquelyMatches(selector, el)) return selector;
        if (p.startsWith("#")) break;
      }
      parts = [];
      for (let cur = el; cur && cur !== document.documentElement; cur = cur.parentElement) {
        parts.unshift(nthPart(cur));
        const selector = parts.join(" > ");
        if (uniquelyMatches(selector, el)) return selector;
      }
      return null;
    }
    """#
}

/// Bounded page controls used only by the optional agent tools.
enum BrowserAgentInteractionScript {
    private static let bootstrap = #"""
    if (!globalThis.__vxAgent) throw new Error('The page snapshot is stale. Take a new snapshot first.');
    globalThis.__vxAgent.setRedactions(typeof redactValues !== 'undefined' ? redactValues : []);
    """#

    static let find = bootstrap + #"""
    const queryText = String(query || '').trim();
    if (!queryText || queryText.length > 240) return JSON.stringify({ error: 'Search text must be 1 to 240 characters.' });
    const matches = [];
    const lower = queryText.toLocaleLowerCase();
    const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
    let node;
    let visitedNodes = 0;
    while ((node = walker.nextNode()) && matches.length < 30 && visitedNodes < 8000) {
      visitedNodes++;
      const parent = node.parentElement;
      if (!parent || parent.isContentEditable || parent.closest('script,style,template,noscript,input,textarea,select,option,button,[contenteditable],[hidden],[aria-hidden="true"],[inert]')) continue;
      let visible = true;
      for (let ancestor = parent; ancestor && ancestor.nodeType === 1; ancestor = ancestor.parentElement) {
        const style = getComputedStyle(ancestor);
        if (ancestor.hasAttribute('hidden') || ancestor.getAttribute('aria-hidden') === 'true' || ancestor.hasAttribute('inert') ||
            style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' || Number(style.opacity) === 0) { visible = false; break; }
      }
      if (!visible) continue;
      const text = node.nodeValue || '';
      let start = 0;
      while (matches.length < 30) {
        const offset = text.toLocaleLowerCase().indexOf(lower, start);
        if (offset < 0) break;
        const range = document.createRange();
        range.setStart(node, offset);
        range.setEnd(node, offset + queryText.length);
        matches.push({ range, parent });
        start = offset + Math.max(queryText.length, 1);
      }
    }
    if (!matches.length) {
      if (globalThis.CSS && CSS.highlights) CSS.highlights.delete('vortyra-agent-find');
      return JSON.stringify({ found: false, count: 0, highlighted: false, searchBoundReached: visitedNodes >= 8000 });
    }
    matches[0].parent.scrollIntoView({ block: 'center', inline: 'nearest' });
    if (!globalThis.CSS || !CSS.highlights || typeof Highlight === 'undefined') {
      return JSON.stringify({ found: true, count: matches.length, highlighted: false, reason: 'This page does not support persistent text highlighting.' });
    }
    const highlight = new Highlight(...matches.map(value => value.range));
    CSS.highlights.set('vortyra-agent-find', highlight);
    let styleElement = document.getElementById('__vortyra_agent_find_style');
    if (!styleElement) {
      styleElement = document.createElement('style');
      styleElement.id = '__vortyra_agent_find_style';
      styleElement.textContent = '::highlight(vortyra-agent-find){background:#ffe066;color:#111}';
      (document.head || document.documentElement).appendChild(styleElement);
    }
    return JSON.stringify({ found: true, count: matches.length, highlighted: true });
    """#

    static let uploadPicker = bootstrap + #"""
    const input = globalThis.__vxAgent.get(Number(id));
    if (!(input instanceof HTMLInputElement) || input.type.toLowerCase() !== 'file') {
      return JSON.stringify({ error: 'The selected element is not a file input.' });
    }
    if (input.disabled || input.getAttribute('aria-disabled') === 'true') return JSON.stringify({ error: 'The file input is disabled.' });
    if (!globalThis.__vxAgent.uploadStates) globalThis.__vxAgent.uploadStates = new WeakMap();
    const state = { status: 'pending', files: [], startedAt: Date.now() };
    globalThis.__vxAgent.uploadStates.set(input, state);
    const record = status => {
      if (globalThis.__vxAgent.uploadStates.get(input) !== state || state.status !== 'pending') return;
      state.status = status;
      state.files = status === 'selected'
        ? Array.from(input.files || []).slice(0, 10).map(file => ({
          name: globalThis.__vxAgent.redact(String(file.name || '')).slice(0, 180),
          size: Math.min(file.size || 0, 1000000000)
        }))
        : [];
    };
    input.addEventListener('change', () => record(input.files && input.files.length ? 'selected' : 'selection_changed_empty'), { once: true });
    input.addEventListener('cancel', () => record('cancelled'), { once: true });
    input.click();
    return JSON.stringify({ pickerRequested: true, status: state.status });
    """#

    static let uploadStatus = bootstrap + #"""
    const input = globalThis.__vxAgent.get(Number(id));
    if (!(input instanceof HTMLInputElement) || input.type.toLowerCase() !== 'file') {
      return JSON.stringify({ error: 'The selected element is not a file input.' });
    }
    const state = globalThis.__vxAgent.uploadStates && globalThis.__vxAgent.uploadStates.get(input);
    if (!state) return JSON.stringify({ status: 'not_requested', files: [] });
    return JSON.stringify({ status: state.status, count: state.files.length, files: state.files, elapsedMs: Math.max(0, Date.now() - state.startedAt) });
    """#

    /// Returns the real target only to the native controller; never include it in model output.
    static let downloadLink = bootstrap + #"""
    const el = globalThis.__vxAgent.get(Number(id));
    if (!(el instanceof HTMLAnchorElement) || !el.href) return JSON.stringify({ error: 'The selected element is not a link.' });
    let url;
    try { url = new URL(el.href); } catch (_) { return JSON.stringify({ error: 'The link has no valid web address.' }); }
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return JSON.stringify({ error: 'Only http and https links can be downloaded.' });
    return JSON.stringify({ url: url.href });
    """#

    static let hover = bootstrap + sensitiveControlGuard + #"""
    const el = globalThis.__vxAgent.get(Number(id));
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') return JSON.stringify({ error: 'Disabled elements cannot receive agent hover events.' });
    if (globalThis.__vxAgent.sensitive(el) || sensitiveControl(el)) return JSON.stringify({ error: 'Sensitive fields cannot receive agent hover events.' });
    const rect = el.getBoundingClientRect();
    el.scrollIntoView({ block: 'center', inline: 'center' });
    const current = el.getBoundingClientRect();
    const init = { bubbles: true, cancelable: true, composed: true, clientX: current.left + current.width / 2, clientY: current.top + current.height / 2, pointerType: 'mouse' };
    for (const type of ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'mousemove']) {
      const EventType = type.startsWith('pointer') ? PointerEvent : MouseEvent;
      el.dispatchEvent(new EventType(type, init));
    }
    return JSON.stringify({ ok: true, synthetic: true, target: globalThis.__vxAgent.describe(el), note: 'Sites may ignore synthetic hover events.' });
    """#

    static let setSlider = bootstrap + sensitiveControlGuard + #"""
    const el = globalThis.__vxAgent.get(Number(id));
    if (!(el instanceof HTMLInputElement) || el.type.toLowerCase() !== 'range') return JSON.stringify({ error: 'The selected element is not a range slider.' });
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') return JSON.stringify({ error: 'The slider is disabled.' });
    if (globalThis.__vxAgent.sensitive(el) || sensitiveControl(el)) return JSON.stringify({ error: 'Sensitive fields cannot be changed by the agent.' });
    const requested = Number(value);
    if (!Number.isFinite(requested)) return JSON.stringify({ error: 'Slider value must be a finite number.' });
    const rawMin = Number(el.min || 0);
    const rawMax = Number(el.max || 100);
    const min = Number.isFinite(rawMin) ? rawMin : 0;
    const max = Number.isFinite(rawMax) ? rawMax : 100;
    const clamped = Math.min(max, Math.max(min, requested));
    const step = el.step === 'any' ? 0 : Number(el.step || 1);
    const snappedValue = step > 0 ? Math.min(max, Math.max(min, min + Math.round((clamped - min) / step) * step)) : clamped;
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(el, String(snappedValue));
    el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    return JSON.stringify({ ok: true, value: el.value, min, max, target: globalThis.__vxAgent.describe(el) });
    """#

    private static let sensitiveControlGuard = #"""
    function sensitiveControl(el) {
      const isInput = el instanceof HTMLInputElement;
      const inputType = isInput ? (el.type || 'text').toLowerCase() : '';
      const isRange = isInput && inputType === 'range';
      const isEditable = el.isContentEditable || el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement ||
        (isInput && !['button', 'submit', 'reset', 'image', 'checkbox', 'radio', 'file', 'range', 'color'].includes(inputType));
      if (!isEditable && !isRange) return false;
      const autocomplete = (el.getAttribute('autocomplete') || '').toLowerCase();
      const hint = [el.name, el.id, el.getAttribute('aria-label'), el.getAttribute('placeholder')].join(' ');
      return /cc-|password|one-time-code/.test(autocomplete)
        || new RegExp('(passw|pwd|card|cc-?num|cvv|cvc|csc|security.?code|expir|iban|routing|account.?num|'
          + 'ssn|social.?security|\\bpin\\b|otp|one.?time)', 'i').test(hint);
    }
    """#

    static let scrollElement = bootstrap + #"""
    const el = globalThis.__vxAgent.get(Number(id));
    el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'auto' });
    return JSON.stringify({ ok: true, target: globalThis.__vxAgent.describe(el), scrollY: Math.round(window.scrollY) });
    """#

    static let dragDrop = bootstrap + #"""
    const source = globalThis.__vxAgent.get(Number(sourceID));
    const target = globalThis.__vxAgent.get(Number(targetID));
    if (source === target || source.contains(target) || target.contains(source)) return JSON.stringify({ error: 'Choose separate source and target elements.' });
    if (source.disabled || target.disabled || source.getAttribute('aria-disabled') === 'true'
      || target.getAttribute('aria-disabled') === 'true')
      return JSON.stringify({ error: 'Disabled elements cannot be dragged.' });
    if (globalThis.__vxAgent.sensitive(source) || globalThis.__vxAgent.sensitive(target)) return JSON.stringify({ error: 'Sensitive fields cannot be drag targets.' });
    if (!source.draggable && !source.hasAttribute('draggable')) return JSON.stringify({ error: 'The source is not marked draggable; inspect extended controls first.' });
    if (!(target.hasAttribute('data-dropzone') || target.hasAttribute('data-drop-target')
      || target.hasAttribute('aria-dropeffect') || target.hasAttribute('ondrop')))
      return JSON.stringify({ error: 'The target is not marked as a drop target; inspect extended controls first.' });
    const transfer = new DataTransfer();
    const sourceRect = source.getBoundingClientRect();
    const targetRect = target.getBoundingClientRect();
    const sourcePoint = { clientX: sourceRect.left + sourceRect.width / 2, clientY: sourceRect.top + sourceRect.height / 2, bubbles: true, cancelable: true, composed: true, dataTransfer: transfer };
    const targetPoint = { clientX: targetRect.left + targetRect.width / 2, clientY: targetRect.top + targetRect.height / 2, bubbles: true, cancelable: true, composed: true, dataTransfer: transfer };
    source.dispatchEvent(new DragEvent('dragstart', sourcePoint));
    target.dispatchEvent(new DragEvent('dragenter', targetPoint));
    target.dispatchEvent(new DragEvent('dragover', targetPoint));
    const notCancelled = target.dispatchEvent(new DragEvent('drop', targetPoint));
    source.dispatchEvent(new DragEvent('dragend', sourcePoint));
    return JSON.stringify({
      ok: true, synthetic: true, dropEventNotCancelled: notCancelled,
      source: globalThis.__vxAgent.describe(source), target: globalThis.__vxAgent.describe(target),
      note: 'Synthetic drag and drop is limited to DOM behavior; native or protected drag sites may ignore it.'
    });
    """#

    static let clearHighlights = bootstrap + #"""
    if (globalThis.CSS && CSS.highlights) CSS.highlights.delete('vortyra-agent-find');
    const style = document.getElementById('__vortyra_agent_find_style');
    if (style) style.remove();
    return JSON.stringify({ cleared: true });
    """#

    static let extendedControls = bootstrap + #"""
    const result = [];
    const seen = new Set();
    const candidates = document.querySelectorAll('[draggable="true"],[data-dropzone],[data-drop-target],[aria-dropeffect],[ondrop],*');
    let visited = 0;
    for (const el of candidates) {
      if (visited++ >= 3000) break;
      if (result.length >= 100) break;
      const style = getComputedStyle(el);
      const rect = el.getBoundingClientRect();
      if (rect.width < 1 || rect.height < 1 || style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) continue;
      const scrollable = /(auto|scroll)/.test(style.overflowY) && el.scrollHeight > el.clientHeight + 16;
      const draggable = el.draggable === true || el.hasAttribute('draggable');
      const dropTarget = el.hasAttribute('data-dropzone') || el.hasAttribute('data-drop-target') || el.hasAttribute('aria-dropeffect') || el.hasAttribute('ondrop');
      if (!scrollable && !draggable && !dropTarget) continue;
      if (el.disabled || el.getAttribute('aria-disabled') === 'true' || globalThis.__vxAgent.sensitive(el)) continue;
      if (seen.has(el)) continue;
      seen.add(el);
      const id = globalThis.__vxAgent.idFor(el);
      const snippet = globalThis.__vxAgent.redact(
        String(el.innerText || el.getAttribute('aria-label') || el.getAttribute('title') || '')
          .replace(/\s+/g, ' ').trim()
      ).slice(0, 100);
      result.push({ id, role: globalThis.__vxAgent.role(el), label: globalThis.__vxAgent.label(el) || snippet || el.tagName.toLowerCase(), scrollable, draggable, dropTarget });
    }
    return JSON.stringify({ controls: result, count: result.length, truncated: candidates.length > 3000 || result.length >= 100 });
    """#

    static let scrollContainer = bootstrap + #"""
    const el = globalThis.__vxAgent.get(Number(id));
    const amount = Math.max(-1000, Math.min(1000, Number(pixels) || 0));
    if (el.disabled || el.getAttribute('aria-disabled') === 'true' || globalThis.__vxAgent.sensitive(el)) return JSON.stringify({ error: 'This element cannot be scrolled by the agent.' });
    if (el.scrollHeight <= el.clientHeight + 1) return JSON.stringify({ error: 'The selected element does not have a scrollable vertical area.' });
    el.scrollBy({ top: amount, behavior: 'auto' });
    return JSON.stringify({ ok: true, scrollTop: Math.round(el.scrollTop), maxScroll: Math.max(0, el.scrollHeight - el.clientHeight), target: globalThis.__vxAgent.describe(el) });
    """#

    static let dismissOverlays = bootstrap + #"""
    const agent = globalThis.__vxAgent;
    const roots = Array.from(document.querySelectorAll('dialog[open],[role="dialog"],[role="alertdialog"],[aria-modal="true"],[id],[class]'))
      .filter(root => {
        const marker = `${root.id || ''} ${typeof root.className === 'string' ? root.className : ''} ${root.getAttribute('aria-label') || ''}`;
        const semantic = root.matches('dialog[open],[role="dialog"],[role="alertdialog"],[aria-modal="true"]');
        return semantic || /cookie|consent|overlay|modal|pop[-_ ]?up|banner/i.test(marker);
      }).slice(0, 40);
    const safeLabel = /^(?:close|dismiss|reject(?: all)?|decline(?: all)?|only (?:essential|necessary)|essential only|necessary only|no thanks)$/i;
    const unsafeLabel = /\b(?:accept|agree|allow|subscribe|purchase|buy|pay|checkout|order|submit|confirm|delete|remove|send|post|publish|sign ?in|log ?in|register|book|reserve)\b/i;
    const dismissed = [];
    const seen = new Set();
    for (const root of roots) {
      if (!root.isConnected || dismissed.length >= 10) continue;
      const candidates = Array.from(root.querySelectorAll('button,[role="button"],a[href],input[type="button"],input[type="submit"]')).slice(0, 40);
      for (const candidate of candidates) {
        if (!candidate.isConnected || seen.has(candidate) || candidate.disabled || candidate.getAttribute('aria-disabled') === 'true' || !agent.visible(candidate)) continue;
        const label = agent.label(candidate) || candidate.innerText || candidate.value || '';
        const normalized = String(label).replace(/\s+/g, ' ').trim();
        if (!safeLabel.test(normalized) || unsafeLabel.test(normalized) || agent.risk(candidate)) continue;
        seen.add(candidate);
        candidate.click();
        dismissed.push(agent.describe(candidate));
        break;
      }
    }
    return JSON.stringify({ dismissed, count: dismissed.length, scannedOverlays: roots.length });
    """#

    static let hideElement = bootstrap + BrowserStableSelectorScript.helpers + #"""
    const agent = globalThis.__vxAgent;
    if (expectedDocumentNonce && expectedDocumentNonce !== agent.documentNonce) return JSON.stringify({ error: 'The page document changed. Take a new snapshot before using this element.' });
    const el = agent.get(Number(id));
    if (el === document.body || el === document.documentElement) return JSON.stringify({ error: 'The whole page cannot be hidden.' });
    if (agent.sensitive(el)) return JSON.stringify({ error: 'Sensitive fields cannot be hidden by the agent.' });
    const selector = selectorFor(el);
    if (!selector || selector.length > 512 || !uniquelyMatches(selector, el)) return JSON.stringify({ error: 'A stable unique selector could not be created for this element.' });
    if (typeof expectedSelector === 'string' && expectedSelector !== selector)
      return JSON.stringify({
        error: 'The selected element changed while approval was pending. Take a new snapshot and try again.'
      });
    const label = agent.label(el) || agent.redact(
      String(el.innerText || el.textContent || el.localName).replace(/\s+/g, ' ').trim()
    ).slice(0, 80);
    return JSON.stringify({ selector, label: label || el.localName });
    """#
}
