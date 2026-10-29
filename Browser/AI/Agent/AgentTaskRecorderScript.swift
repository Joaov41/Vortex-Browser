//
//  AgentTaskRecorderScript.swift
//  Vortex
//
//  Page script for teach mode. It runs in a private content world, only while a
//  recording is active, and reports user actions to the native recorder. It never
//  reports the value of a sensitive, hidden or non-plain field.
//

import Foundation
import WebKit

enum AgentTaskRecorderScript {
    static let world = WKContentWorld.world(name: "VortyraTeachRecorder")
    static let messageHandlerName = "vortyraTeachRecorder"

    /// The bootstrap installs `agent` in this world, so `agent.sensitive` is the same
    /// detector the agent uses to refuse or mask fields. The IIFE keeps its `const`s local.
    static let source = "(() => {\n" + BrowserAgentPageScript.bootstrap + "\n" + recorderBody + "\n})();"

    /// Removes the listeners and the page-side state. Safe to run when nothing is installed.
    static let teardownSource = """
    if (globalThis.__vxTeachRecorder) {
      globalThis.__vxTeachRecorder.stop();
      delete globalThis.__vxTeachRecorder;
    }
    """

    private static let recorderBody = #"""
    if (globalThis.__vxTeachRecorder) return;
    const handler = globalThis.webkit && globalThis.webkit.messageHandlers
      && globalThis.webkit.messageHandlers.vortyraTeachRecorder;
    if (!handler) return;

    const MAX_VALUE = 500;
    const MAX_HINT = 300;
    const PLAIN_INPUT_TYPES = ['', 'text', 'search'];
    const NON_TEXT_INPUT_TYPES = ['checkbox', 'radio', 'button', 'submit', 'reset', 'image'];
    const CLICKABLE = 'a[href],button,input[type=button],input[type=submit],input[type=reset],' +
      'input[type=image],input[type=checkbox],input[type=radio],summary,[role=button],[role=link],' +
      '[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=option],[role=switch]';

    let sawSubmitClick = false;
    let editing = null;
    let editingText = '';

    const send = payload => { try { handler.postMessage(payload); } catch (_) {} };
    const clip = (text, max) => String(text == null ? '' : text).replace(/\s+/g, ' ').trim().slice(0, max);
    const pageURL = () => location.href;

    const isValueBearing = el => el.isContentEditable || el instanceof HTMLTextAreaElement ||
      el instanceof HTMLSelectElement ||
      (el instanceof HTMLInputElement && !NON_TEXT_INPUT_TYPES.includes((el.type || 'text').toLowerCase()));

    // Value-bearing controls never use innerText as a label, because that can contain typed text.
    const labelFor = el => {
      if (!isValueBearing(el)) return clip(agent.label(el), 120);
      const labels = el.labels ? Array.from(el.labels).map(l => l.innerText).join(' ') : '';
      return clip(el.getAttribute('aria-label') || labels || el.getAttribute('placeholder') ||
        el.getAttribute('title') || el.getAttribute('name') || '', 120);
    };

    const sensitiveField = el => agent.sensitive(el) || agent.sensitiveText(labelFor(el));

    const hintFor = el => {
      const parts = [el.tagName.toLowerCase()];
      const type = el.getAttribute('type');
      if (type) parts.push('[type="' + type + '"]');
      const name = el.getAttribute('name');
      if (name) parts.push('[name="' + name + '"]');
      if (el.id) parts.push('#' + el.id);
      return clip(parts.join(''), MAX_HINT);
    };

    const describe = el => ({ label: labelFor(el), role: agent.role(el), selectorHint: hintFor(el) });

    const isNavigatingLink = el => {
      if (!(el instanceof HTMLAnchorElement) || !el.href) return false;
      if (el.hasAttribute('download') || (el.target && el.target !== '_self')) return false;
      try {
        const next = new URL(el.href);
        if (!/^https?:$/.test(next.protocol)) return false;
        return next.href.split('#')[0] !== location.href.split('#')[0];
      } catch (_) {
        return false;
      }
    };

    const step = fields => send({ type: 'step', step: fields });

    const onClick = event => {
      const target = event.target instanceof Element ? event.target : null;
      if (!target) return;
      const el = target.closest(CLICKABLE);
      if (!el || agent.isTextField(el)) return;
      const isSubmitControl = (el.tagName === 'BUTTON' && el.type === 'submit') ||
        (el.tagName === 'INPUT' && ['submit', 'image'].includes((el.type || '').toLowerCase()));
      if (isSubmitControl) {
        sawSubmitClick = true;
        setTimeout(() => { sawSubmitClick = false; }, 0);
      }
      step({
        kind: 'click', ...describe(el), url: pageURL(), value: null, needsUserInput: false,
        navigates: isSubmitControl || isNavigatingLink(el)
      });
    };

    const onSubmit = event => {
      if (sawSubmitClick) return;
      const form = event.target instanceof HTMLFormElement ? event.target : null;
      if (!form) return;
      const submitter = event.submitter instanceof Element ? event.submitter : null;
      const label = submitter ? labelFor(submitter) : clip(form.getAttribute('aria-label'), 120);
      step({
        kind: 'submit', label, role: 'form', selectorHint: hintFor(form), url: pageURL(),
        value: null, needsUserInput: false, navigates: true
      });
    };

    // Text is recorded on change (blur or commit), never per keystroke.
    const onChange = event => {
      const el = event.target;
      if (el instanceof HTMLSelectElement) {
        const option = el.selectedOptions && el.selectedOptions[0];
        const text = option ? String(option.text).slice(0, MAX_VALUE) : '';
        const plain = text !== '' && !sensitiveField(el);
        step({ kind: 'select', ...describe(el), url: pageURL(), value: plain ? text : null, needsUserInput: !plain, navigates: false });
        return;
      }
      if (el instanceof HTMLTextAreaElement) {
        step({ kind: 'input', ...describe(el), url: pageURL(), value: null, needsUserInput: true, navigates: false });
        return;
      }
      if (el instanceof HTMLInputElement) {
        const type = (el.type || 'text').toLowerCase();
        if (NON_TEXT_INPUT_TYPES.includes(type)) return;
        const plain = PLAIN_INPUT_TYPES.includes(type) && !sensitiveField(el);
        if (plain && el.value === '') return;
        step({
          kind: 'input', ...describe(el), url: pageURL(),
          value: plain ? String(el.value).slice(0, MAX_VALUE) : null,
          needsUserInput: !plain, navigates: false
        });
      }
    };

    // Contenteditable has no change event. Record it on focus-out when its text changed, without the text.
    const onFocusIn = event => {
      const el = event.target;
      if (el instanceof HTMLElement && el.isContentEditable) {
        editing = el;
        editingText = el.innerText;
      }
    };

    const onFocusOut = event => {
      const el = event.target;
      if (!editing || el !== editing) return;
      const changed = el.innerText !== editingText;
      editing = null;
      editingText = '';
      if (changed) {
        step({ kind: 'input', ...describe(el), url: pageURL(), value: null, needsUserInput: true, navigates: false });
      }
    };

    const listeners = [
      ['click', onClick, true],
      ['submit', onSubmit, true],
      ['change', onChange, true],
      ['focusin', onFocusIn, true],
      ['focusout', onFocusOut, true]
    ];
    listeners.forEach(([type, fn, capture]) => document.addEventListener(type, fn, capture));

    globalThis.__vxTeachRecorder = {
      stop() {
        listeners.forEach(([type, fn, capture]) => document.removeEventListener(type, fn, capture));
      }
    };
    send({ type: 'ready', url: pageURL(), title: document.title, nonce: agent.documentNonce });
    """#
}
