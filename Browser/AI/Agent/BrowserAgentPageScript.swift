//
//  BrowserAgentPageScript.swift
//  Vortex
//
//  JavaScript the browser agent runs in the page. Everything executes in a
//  private WKContentWorld: the page shares the DOM with it but cannot read or
//  replace the agent's element map or helper functions.
//

import Foundation
import WebKit

enum BrowserAgentPageScript {
    static let world = WKContentWorld.world(name: "VortyraAgent")

    /// Installs `globalThis.__vxAgent` once per document in the agent world.
    /// Prepended to every call; after a navigation the new document gets a
    /// fresh copy and old element ids stop resolving.
    private static let bootstrap = #"""
    if (!globalThis.__vxAgent) {
      const RISKY = new RegExp(
        '\\b(buy|purchase|pay|checkout|check out|place order|order now|subscribe|donate|'
          + 'transfer|send|post|publish|tweet|reply|comment|submit|delete|remove|'
          + 'cancel (my )?(order|subscription|account)|unsubscribe|confirm|book now|reserve|'
          + 'sign up|register|log ?out|sign ?out)\\b', 'i');
      const SENSITIVE_NAME = new RegExp(
        '(passw|pwd|secret|token|credential|cookie|session|api.?key|card|cc-?num|cvv|cvc|csc|'
          + 'security.?code|expir|iban|routing|account.?num|ssn|social.?security|\\bpin\\b|otp|one.?time)',
        'i');
      const AUTH_SENSITIVE_NAME = /(?:^|[^a-z0-9])auth(?:$|[^a-z0-9]|entication|orization|orize|enticate|token|key|credential|password|code|enticator)|(?:^|[^a-z0-9])oauth2?(?:$|[^a-z0-9])/i;
      const isSensitiveName = value => SENSITIVE_NAME.test(String(value || '')) || AUTH_SENSITIVE_NAME.test(String(value || ''));
      const INTERACTIVE = 'a[href],button,input:not([type=hidden]),textarea,select,summary,' +
        '[role=button],[role=link],[role=checkbox],[role=radio],[role=tab],[role=menuitem],' +
        '[role=option],[role=switch],[role=combobox],[role=textbox],[role=searchbox],' +
        '[contenteditable=""],[contenteditable=true],[onclick]';

      const clean = (s, max) => {
        const t = agent.redact(String(s || '').replace(/\s+/g, ' ').trim());
        return t.length > max ? t.slice(0, max - 1) + '…' : t;
      };

      const agent = {
        refs: new Map(),
        ids: new WeakMap(),
        nextId: 1,
        screenshotMaskOwner: null,
        screenshotMaskSequence: 0,
        screenshotMask: [],
        pendingRisk: new Map(),
        redactionValues: [],

        setRedactions(values) {
          agent.redactionValues = (Array.isArray(values) ? values : [])
            .map(value => String(value || ''))
            .filter(value => value.length >= 2)
            .sort((a, b) => b.length - a.length);
        },

        // Runs before every clip so a sensitive value can never leave the
        // world as a truncated prefix either.
        redact(text) {
          let out = String(text ?? '');
          for (const value of agent.redactionValues) {
            if (value) out = out.split(value).join('[redacted]');
          }
          return out;
        },
        documentNonce: globalThis.crypto && typeof globalThis.crypto.randomUUID === 'function'
          ? globalThis.crypto.randomUUID()
          : `${Date.now().toString(36)}:${Math.random().toString(36).slice(2)}`,

        collect(root, out) {
          root.querySelectorAll(INTERACTIVE).forEach(el => out.push(el));
          root.querySelectorAll('*').forEach(el => { if (el.shadowRoot) agent.collect(el.shadowRoot, out); });
          return out;
        },

        visible(el) {
          const r = el.getBoundingClientRect();
          if (r.width < 1 || r.height < 1) return null;
          const s = getComputedStyle(el);
          if (s.visibility === 'hidden' || s.display === 'none' || parseFloat(s.opacity) === 0) return null;
          return r;
        },

        role(el) {
          const explicit = el.getAttribute('role');
          if (explicit) return explicit;
          const tag = el.tagName.toLowerCase();
          if (tag === 'a') return 'link';
          if (tag === 'select') return 'select';
          if (tag === 'textarea') return 'textbox';
          if (tag === 'summary') return 'button';
          if (tag === 'input') {
            const type = (el.type || 'text').toLowerCase();
            if (['button', 'submit', 'reset', 'image'].includes(type)) return 'button';
            if (['checkbox', 'radio'].includes(type)) return type;
            if (type === 'search') return 'searchbox';
            return 'textbox';
          }
          if (el.isContentEditable) return 'textbox';
          return tag === 'button' ? 'button' : 'clickable';
        },

        label(el) {
          const byId = (el.getAttribute('aria-labelledby') || '').split(/\s+/)
            .map(id => id && document.getElementById(id)).filter(Boolean)
            .map(n => n.innerText).join(' ');
          const fromLabels = el.labels ? Array.from(el.labels).map(l => l.innerText).join(' ') : '';
          const isButtonInput = el.tagName === 'INPUT' && ['button', 'submit', 'reset'].includes((el.type || '').toLowerCase());
          return clean(
            el.getAttribute('aria-label') || byId || fromLabels ||
            (isButtonInput ? el.value : '') ||
            el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('alt') ||
            el.innerText || el.querySelector('img[alt]')?.getAttribute('alt') || el.getAttribute('name') || '',
            80
          );
        },

        isTextField(el) {
          if (el.isContentEditable) return true;
          if (el.tagName === 'TEXTAREA') return true;
          if (el.tagName !== 'INPUT') return false;
          return !['button', 'submit', 'reset', 'image', 'checkbox', 'radio', 'file', 'range', 'color'].includes((el.type || 'text').toLowerCase());
        },

        sensitive(el) {
          if (el.tagName === 'INPUT' && (el.type || '').toLowerCase() === 'password') return true;
          const ac = (el.getAttribute('autocomplete') || '').toLowerCase();
          if (/cc-|password|one-time-code/.test(ac)) return true;
          const hint = [el.name, el.id, el.getAttribute('aria-label'), el.getAttribute('placeholder')].join(' ');
          return agent.isTextField(el) && isSensitiveName(hint);
        },

        risk(el) {
          const text = [agent.label(el), el.value && el.tagName === 'INPUT' ? el.value : ''].join(' ');
          const match = text.match(RISKY);
          if (match) return match[0].toLowerCase();
          const form = el.form || el.closest('form');
          const isSubmit = (el.tagName === 'BUTTON' && (el.type || 'submit') === 'submit') ||
            (el.tagName === 'INPUT' && ['submit', 'image'].includes((el.type || '').toLowerCase()));
          return form && isSubmit ? agent.formRisk(form) : null;
        },

        // Search and other GET forms are safe to submit; sign-in, POST and
        // payment forms need the user's approval.
        formRisk(form) {
          if (form.querySelector('input[type=password]')) return 'sign-in form';
          const fields = Array.from(form.querySelectorAll('input,textarea'));
          if (fields.some(f => agent.sensitive(f))) return 'form with sensitive fields';
          const isSearch = form.getAttribute('role') === 'search' || form.closest('[role=search]') ||
            form.querySelector('input[type=search],input[name=q],input[name=query],input[name=search]') ||
            /search/i.test(form.getAttribute('action') || '');
          if (isSearch) return null;
          return (form.method || 'get').toLowerCase() === 'post' ? 'form submission' : null;
        },

        defaultSubmitter(form) {
          return Array.from(document.querySelectorAll('button,input[type=submit],input[type=image]'))
            .find(candidate => candidate.form === form && !candidate.disabled &&
              (candidate.type === 'submit' || candidate.type === 'image')) || null;
        },

        riskContext(el, operation, key) {
          const form = el.form || el.closest('form');
          const isEnterSubmit = operation === 'press_key' && key === 'Enter' && agent.isTextField(el);
          const isRequestedSubmit = operation === 'type_text' && key === 'submit';
          const submitter = (isEnterSubmit || isRequestedSubmit) && form ? agent.defaultSubmitter(form) : null;
          let reason = operation === 'press_key' && !['Enter', 'Space'].includes(key)
            ? null
            : agent.risk(el);
          if ((isEnterSubmit || isRequestedSubmit) && form) {
            reason = agent.formRisk(form) || reason || (submitter ? agent.risk(submitter) : null);
          }
          const formHints = form ? [
            form.getAttribute('action'), form.getAttribute('name'), form.id,
            form.getAttribute('aria-label'), form.getAttribute('autocomplete'), form.getAttribute('role')
          ].join(' ') : '';
          const formLabels = form ? Array.from(form.querySelectorAll('label,[aria-label],button,input[type=submit]'))
            .slice(0, 30).map(node => node.getAttribute('aria-label') || node.innerText || node.value || '').join(' ') : '';
          const hasUsernameAutocomplete = Boolean(form && Array.from(form.querySelectorAll('[autocomplete]'))
            .some(field => (field.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/).includes('username')));
          let actionPath = '';
          if (form) {
            try { actionPath = new URL(form.getAttribute('action') || '', document.baseURI).pathname.toLowerCase(); } catch (_) {}
          }
          const authActionPath = actionPath.split('/').some(segment =>
            /^(?:auth|authenticate|authentication|authorization|authorize|oauth2?|sso|login|log-in|signin|sign-in)(?:[-_](?:callback|complete|continue|redirect|start))?$/.test(segment)
          );
          const signInHint = authActionPath ||
            new RegExp('sign[ -]?in|log[ -]?in|login|\\bauth(?:enticate|entication|orization|orize)?\\b|'
              + '\\boauth\\b|\\bsso\\b|checkout|payment|billing', 'i').test(formHints + ' ' + formLabels);
          const protectedContext = Boolean(form && (
            form.querySelector('input[type=password]') ||
            Array.from(form.querySelectorAll('input,textarea,select')).some(field => agent.sensitive(field)) ||
            signInHint ||
            (hasUsernameAutocomplete && ((form.method || 'get').toLowerCase() === 'post' || signInHint))
          ));
          return {
            operation,
            key: key === 'submit' ? 'submit' : key || '',
            reason: reason || '',
            protectedContext,
            target: {
              tag: el.tagName,
              type: (el.getAttribute('type') || '').toLowerCase(),
              role: agent.role(el),
              id: el.id || '',
              name: el.getAttribute('name') || '',
              disabled: el.matches(':disabled') || el.getAttribute('aria-disabled') === 'true',
              readOnly: el.readOnly === true || el.getAttribute('aria-readonly') === 'true',
              inert: Boolean(el.closest('[inert]')),
              label: clean(agent.label(el), 250),
              href: el instanceof HTMLAnchorElement ? el.href : ''
            },
            form: form ? {
              action: form.action,
              method: (form.method || 'get').toLowerCase(),
              id: form.id || '',
              name: form.getAttribute('name') || '',
              autocomplete: form.getAttribute('autocomplete') || '',
              hints: clean(formHints + ' ' + formLabels, 500)
            } : null,
            submitter: submitter ? {
              tag: submitter.tagName,
              type: (submitter.getAttribute('type') || '').toLowerCase(),
              label: clean(agent.label(submitter), 250),
              name: submitter.getAttribute('name') || ''
            } : null
          };
        },

        prepareRisk(el, operation, key, approvalID, confirmationContextID, confirmed, expectedDocumentNonce) {
          if (expectedDocumentNonce && expectedDocumentNonce !== agent.documentNonce) {
            return { error: 'The page document changed. Take a new snapshot before using this element.' };
          }
          const identity = String(approvalID || '');
          if (!identity) return { error: 'This action is missing its run-scoped confirmation identity.' };
          const context = agent.riskContext(el, operation, key);
          const fingerprint = JSON.stringify(context);
          if (confirmed !== true) {
            if (!context.reason) return { ticket: { el, operation, key, fingerprint, contextID: null } };
            if (agent.pendingRisk.size > 8) agent.pendingRisk.clear();
            const ticket = { el, operation, key, fingerprint, contextID: identity, risk: context.reason, protectedContext: context.protectedContext };
            agent.pendingRisk.set(identity, ticket);
            return {
              needsConfirmation: true,
              approvalID: identity,
              contextID: identity,
              reason: context.reason,
              target: agent.describe(el),
              protectedContext: context.protectedContext,
              trustEligible: !context.protectedContext
            };
          }
          const pending = agent.pendingRisk.get(identity);
          if (!pending || pending.el !== el || pending.operation !== operation || pending.key !== key ||
              pending.contextID !== String(confirmationContextID || '') || pending.fingerprint !== fingerprint) {
            agent.pendingRisk.delete(identity);
            return { error: 'The approved target or its form context changed. Review a fresh page snapshot and approve again.' };
          }
          return { ticket: pending };
        },

        riskContextStillMatches(ticket, el, operation, key) {
          if (!ticket || ticket.el !== el || ticket.operation !== operation || ticket.key !== key) return false;
          return ticket.fingerprint === JSON.stringify(agent.riskContext(el, operation, key));
        },

        idFor(el) {
          let id = agent.ids.get(el);
          if (!id) { id = agent.nextId++; agent.ids.set(el, id); }
          agent.refs.set(id, el);
          return id;
        },

        get(id) {
          const el = agent.refs.get(Number(id));
          if (!el || !el.isConnected) throw new Error(`Element [${id}] is no longer on the page. Use the ids from the latest snapshot.`);
          return el;
        },

        describe(el) {
          return `${agent.role(el)} "${agent.label(el)}"`;
        },

        snapshot(maxElements, maxText) {
          agent.refs = new Map();
          const vh = innerHeight, vw = innerWidth;
          const seen = new Set();
          const items = [];
          for (const el of agent.collect(document, [])) {
            if (seen.has(el)) continue;
            seen.add(el);
            if (el.closest('[aria-hidden=true],[inert]')) continue;
            const r = agent.visible(el);
            if (!r) continue;
            const onScreen = r.bottom > 0 && r.top < vh && r.right > 0 && r.left < vw;
            items.push({ el, onScreen, top: r.top });
          }
          items.sort((a, b) => (a.onScreen === b.onScreen) ? a.top - b.top : (a.onScreen ? -1 : 1));
          const lines = [];
          for (const { el, onScreen } of items.slice(0, maxElements)) {
            const id = agent.idFor(el);
            const role = agent.role(el);
            let line = `[${id}] ${role} "${agent.label(el)}"`;
            if (agent.sensitive(el)) {
              line += ' (sensitive: you cannot type here)';
            } else if (agent.isTextField(el)) {
              const value = el.isContentEditable ? el.innerText : el.value;
              line += ` value="${clean(value, 60)}"`;
            }
            if (el.tagName === 'SELECT') {
              const opts = Array.from(el.options).slice(0, 12).map(o => clean(o.text, 30));
              line += ` selected="${clean(el.selectedOptions[0]?.text, 30)}" options=[${opts.join(' | ')}]`;
            }
            if (role === 'checkbox' || role === 'radio' || role === 'switch') {
              const on = el.checked ?? (el.getAttribute('aria-checked') === 'true');
              line += on ? ' checked' : ' unchecked';
            }
            if (el.disabled || el.getAttribute('aria-disabled') === 'true') line += ' disabled';
            if (role === 'link') {
              try { line += ` → ${new URL(el.href).pathname.slice(0, 60)}`; } catch (_) {}
            }
            if (!onScreen) line += ' (offscreen)';
            lines.push(line);
          }
          const text = clean(document.body ? document.body.innerText : '', maxText);
          return {
            url: location.href,
            title: agent.redact(document.title),
            scrollY: Math.round(scrollY),
            scrollHeight: Math.round(document.documentElement.scrollHeight),
            viewportHeight: Math.round(vh),
            elementCount: items.length,
            elements: lines.join('\n'),
            text
          };
        },

        highlight(el) {
          const r = el.getBoundingClientRect();
          const box = document.createElement('div');
          box.style.cssText = `position:fixed;left:${r.left - 3}px;top:${r.top - 3}px;width:${r.width + 6}px;height:${r.height + 6}px;` +
            'border:2px solid #7c5cff;border-radius:6px;background:rgba(124,92,255,.15);' +
            'pointer-events:none;z-index:2147483647;transition:opacity .4s;';
          document.documentElement.appendChild(box);
          setTimeout(() => { box.style.opacity = '0'; }, 700);
          setTimeout(() => box.remove(), 1150);
        },

        async reveal(el) {
          el.scrollIntoView({ block: 'center', inline: 'center' });
          await new Promise(r => setTimeout(r, 120));
          agent.highlight(el);
        },

        async click(id, confirmed, approvalID, confirmationContextID, expectedDocumentNonce) {
          const el = agent.get(id);
          if (el.matches(':disabled') || el.getAttribute('aria-disabled') === 'true' || el.closest('[inert]')) {
            return { error: 'Disabled or inert elements cannot receive agent clicks.' };
          }
          const prepared = agent.prepareRisk(el, 'click', '', approvalID, confirmationContextID, confirmed, expectedDocumentNonce);
          if (prepared.error || prepared.needsConfirmation) return prepared;
          const ticket = prepared.ticket;
          await agent.reveal(el);
          if (!agent.riskContextStillMatches(ticket, el, 'click', '')) {
            agent.pendingRisk.delete(String(approvalID));
            return { error: 'The target or its protected context changed before the click. Review the page and try again.' };
          }
          agent.pendingRisk.delete(String(approvalID));
          const r = el.getBoundingClientRect();
          const opts = { bubbles: true, cancelable: true, composed: true, view: window,
            clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
          el.dispatchEvent(new PointerEvent('pointerdown', opts));
          el.dispatchEvent(new MouseEvent('mousedown', opts));
          if (typeof el.focus === 'function') el.focus({ preventScroll: true });
          el.dispatchEvent(new PointerEvent('pointerup', opts));
          el.dispatchEvent(new MouseEvent('mouseup', opts));
          if (!agent.riskContextStillMatches(ticket, el, 'click', '') ||
              el.matches(':disabled') || el.getAttribute('aria-disabled') === 'true' || el.closest('[inert]')) {
            agent.pendingRisk.delete(String(approvalID));
            return { error: 'The target or its protected context changed during the click. Review the page and approve again.' };
          }
          el.click();
          return { ok: true, target: agent.describe(el), approvalContextID: ticket.contextID };
        },

        async type(id, text, submit, confirmed, approvalID, confirmationContextID, expectedDocumentNonce) {
          const el = agent.get(id);
          if (agent.sensitive(el)) return { blocked: 'This is a password, payment or other sensitive field. The user must fill it in themselves.' };
          if (!agent.isTextField(el)) return { error: `[${id}] is not a text field.` };
          if (el.matches(':disabled') || el.getAttribute('aria-disabled') === 'true' || el.closest('[inert]') ||
              el.readOnly === true || el.getAttribute('aria-readonly') === 'true') {
            return { error: 'Disabled, inert, or read-only fields cannot be changed.' };
          }
          const form = el.form || el.closest('form');
          const operationKey = submit ? 'submit' : '';
          const prepared = agent.prepareRisk(el, 'type_text', operationKey, approvalID, confirmationContextID, confirmed, expectedDocumentNonce);
          if (prepared.error || prepared.needsConfirmation) return prepared;
          const ticket = prepared.ticket;
          await agent.reveal(el);
          if (!agent.riskContextStillMatches(ticket, el, 'type_text', operationKey)) {
            agent.pendingRisk.delete(String(approvalID));
            return { error: 'The target or its protected form context changed before typing. Review the page and try again.' };
          }
          agent.pendingRisk.delete(String(approvalID));
          el.focus();
          if (!agent.riskContextStillMatches(ticket, el, 'type_text', operationKey) ||
              agent.sensitive(el) || !agent.isTextField(el) || el.matches(':disabled') ||
              el.getAttribute('aria-disabled') === 'true' || el.closest('[inert]') ||
              el.readOnly === true || el.getAttribute('aria-readonly') === 'true') {
            return { error: 'The target or its protected form context changed when it received focus. Review the page before typing.' };
          }
          if (el.isContentEditable) {
            document.getSelection().selectAllChildren(el);
            document.execCommand('insertText', false, text);
          } else {
            const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, text);
            el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: text }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          }
          if (submit) {
            const key = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
            const proceed = el.dispatchEvent(new KeyboardEvent('keydown', key));
            el.dispatchEvent(new KeyboardEvent('keypress', key));
            el.dispatchEvent(new KeyboardEvent('keyup', key));
            if (proceed && form) {
              if (ticket.fingerprint !== JSON.stringify(agent.riskContext(el, 'type_text', operationKey))) {
                return { error: 'The form or its submit action changed after typing. Review the updated form before submitting.' };
              }
              const submitter = agent.defaultSubmitter(form);
              if (typeof form.requestSubmit === 'function') form.requestSubmit(submitter instanceof HTMLElement ? submitter : undefined); else form.submit();
            }
          }
          return { ok: true, target: agent.describe(el), approvalContextID: ticket.contextID };
        },

        async select(id, option) {
          const el = agent.get(id);
          if (el.tagName !== 'SELECT') return { error: `[${id}] is not a dropdown. Click it and pick the option instead.` };
          const want = String(option).trim().toLowerCase();
          const opts = Array.from(el.options);
          const match = opts.find(o => o.value.toLowerCase() === want || o.text.trim().toLowerCase() === want) ||
            opts.find(o => o.text.toLowerCase().includes(want));
          if (!match) return { error: `No option matching "${option}". Options: ${opts.slice(0, 20).map(o => clean(o.text, 30)).join(' | ')}` };
          await agent.reveal(el);
          el.value = match.value;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return { ok: true, target: `${agent.describe(el)} → "${clean(match.text, 40)}"` };
        },

        async pressKey(key, id, confirmed, expectedDocumentNonce, approvalID, confirmationContextID) {
          if (expectedDocumentNonce && expectedDocumentNonce !== agent.documentNonce) {
            return { error: 'The page document changed. Take a new snapshot before using this element.' };
          }
          const allowed = new Set(['Enter', 'Escape', 'Tab', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Backspace', 'Space']);
          if (!allowed.has(key)) return { error: 'That key is not supported by the browser agent.' };
          let el;
          try { el = id === null || id === undefined ? document.activeElement : agent.get(Number(id)); }
          catch (error) { return { error: String(error.message || error) }; }
          if (!(el instanceof HTMLElement) || !el.isConnected) return { error: 'Focus an element or choose an element ID from the latest snapshot.' };
          if (el.matches(':disabled') || el.getAttribute('aria-disabled') === 'true' || el.closest('[inert]')) {
            return { error: 'Disabled or inert elements cannot receive agent keyboard actions.' };
          }
          const readOnly = el.readOnly === true || el.getAttribute('aria-readonly') === 'true';
          if (readOnly && ['Enter', 'Backspace', 'Space'].includes(key)) return { error: 'Read-only fields cannot be changed or submitted by keyboard tools.' };
          if (el !== document.activeElement && typeof el.focus === 'function') el.focus({ preventScroll: true });

          const isSpaceAction = key === 'Space' && (
            el.matches('button,input[type=button],input[type=submit],input[type=checkbox],input[type=radio],'
              + '[role=button],[role=checkbox],[role=radio],[role=switch]')
            || agent.isTextField(el));
          if ((key === 'Backspace' || key === 'Space') && agent.isTextField(el) && agent.sensitive(el)) {
            return { blocked: 'Sensitive fields cannot be changed by keyboard tools. The user must edit them themselves.' };
          }
          const prepared = agent.prepareRisk(el, 'press_key', key, approvalID, confirmationContextID, confirmed, expectedDocumentNonce);
          if (prepared.error || prepared.needsConfirmation) return prepared;
          const ticket = prepared.ticket;

          const keyName = key === 'Space' ? ' ' : key;
          const code = key === 'Space' ? 'Space' : key;
          const codes = { Enter: 13, Escape: 27, Tab: 9, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39, Backspace: 8, Space: 32 };
          const eventInit = { key: keyName, code, keyCode: codes[key], which: codes[key], bubbles: true, cancelable: true, composed: true };
          const keydown = new KeyboardEvent('keydown', eventInit);
          const proceed = el.dispatchEvent(keydown);
          if (!agent.riskContextStillMatches(ticket, el, 'press_key', key)) {
            agent.pendingRisk.delete(String(approvalID));
            return { error: 'The target or its form context changed during the key event. Review the page before continuing.' };
          }
          agent.pendingRisk.delete(String(approvalID));
          if (proceed) {
            if (key === 'Tab') {
              const candidates = Array.from(document.querySelectorAll('a[href],button,input:not([type=hidden]),select,textarea,[tabindex],[contenteditable="true"],[contenteditable=""]'))
                .filter(candidate => candidate instanceof HTMLElement && candidate.tabIndex >= 0 && !candidate.disabled
                  && candidate.getAttribute('aria-disabled') !== 'true'
                  && !candidate.closest('[inert],[aria-hidden="true"]') && agent.visible(candidate));
              const current = candidates.indexOf(el);
              const next = candidates.length ? candidates[(current < 0 ? 0 : (current + 1) % candidates.length)] : null;
              if (next) next.focus({ preventScroll: true });
            } else if (key === 'Backspace') {
              if (!(el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) || typeof el.setRangeText !== 'function' || el.type === 'number') {
                return { error: 'Backspace is supported only in a text input or text area.' };
              }
              const value = el.value;
              let start = el.selectionStart ?? value.length;
              let end = el.selectionEnd ?? start;
              if (start === end && start > 0) {
                const last = value.charCodeAt(start - 1);
                const prior = start > 1 ? value.charCodeAt(start - 2) : 0;
                start -= last >= 0xDC00 && last <= 0xDFFF && prior >= 0xD800 && prior <= 0xDBFF ? 2 : 1;
              }
              if (start !== end) {
                el.setRangeText('', start, end, 'end');
                el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'deleteContentBackward' }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
              }
            } else if (key === 'Space' && agent.isTextField(el)) {
              if (!(el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) || typeof el.setRangeText !== 'function' || el.type === 'number') {
                return { error: 'Space is supported only in a text input or text area.' };
              }
              const start = el.selectionStart ?? el.value.length;
              const end = el.selectionEnd ?? start;
              el.setRangeText(' ', start, end, 'end');
              el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: ' ' }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
            } else if (key === 'Enter') {
              const form = el.form || el.closest('form');
              if (agent.isTextField(el) && form) {
                const submitter = agent.defaultSubmitter(form);
                if (typeof form.requestSubmit === 'function') form.requestSubmit(submitter instanceof HTMLElement ? submitter : undefined);
                else form.submit();
              } else if (el.matches('a[href],button,input[type=button],input[type=submit],[role=button],[role=link]')) {
                el.click();
              }
            } else if (key === 'Space' && isSpaceAction && !agent.isTextField(el)) {
              el.click();
            } else if (key.startsWith('Arrow') && el instanceof HTMLSelectElement && el.options.length) {
              const delta = key === 'ArrowDown' || key === 'ArrowRight' ? 1 : -1;
              const nextIndex = Math.min(el.options.length - 1, Math.max(0, (el.selectedIndex < 0 ? 0 : el.selectedIndex) + delta));
              if (nextIndex !== el.selectedIndex) {
                el.selectedIndex = nextIndex;
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
              }
            } else if (key === 'Escape') {
              const dialog = el.closest('dialog[open]');
              if (dialog && typeof dialog.close === 'function') dialog.close();
            }
          }
          const active = document.activeElement;
          const keyupTarget = active instanceof HTMLElement ? active : el;
          keyupTarget.dispatchEvent(new KeyboardEvent('keyup', eventInit));
          return { ok: true, key, target: agent.describe(el), activeElement: active instanceof HTMLElement ? agent.describe(active) : '', approvalContextID: ticket.contextID };
        },

        setChecked(id, checked, confirmed, expectedDocumentNonce, approvalID, confirmationContextID) {
          if (expectedDocumentNonce && expectedDocumentNonce !== agent.documentNonce) {
            return { error: 'The page document changed. Take a new snapshot before using this element.' };
          }
          const el = agent.get(Number(id));
          const role = agent.role(el);
          const nativeCheck = el instanceof HTMLInputElement && ['checkbox', 'radio'].includes((el.type || '').toLowerCase());
          if (!nativeCheck && !['checkbox', 'radio', 'switch'].includes(role)) return { error: 'Choose a checkbox, radio button, or switch from the latest snapshot.' };
          if (el.matches(':disabled') || el.getAttribute('aria-disabled') === 'true' || el.closest('[inert]')) return { error: 'Disabled controls cannot be changed.' };
          if (agent.sensitive(el)) return { error: 'Sensitive controls cannot be changed by the agent.' };
          const wanted = checked === true;
          const current = nativeCheck ? el.checked : el.getAttribute('aria-checked') === 'true';
          if (current === wanted) return { ok: true, changed: false, checked: wanted, target: agent.describe(el) };
          if (role === 'radio' && !wanted) return { error: 'A selected radio button cannot be unchecked by itself.' };
          const prepared = agent.prepareRisk(el, 'set_checked', '', approvalID, confirmationContextID, confirmed, expectedDocumentNonce);
          if (prepared.error || prepared.needsConfirmation) return prepared;
          const ticket = prepared.ticket;
          if (!agent.riskContextStillMatches(ticket, el, 'set_checked', '')) {
            agent.pendingRisk.delete(String(approvalID));
            return { error: 'The target changed before its checked state could be changed.' };
          }
          agent.pendingRisk.delete(String(approvalID));
          if (nativeCheck) {
            el.click();
            if (el.checked !== wanted) return { error: 'The page prevented this control from changing.' };
          } else {
            el.click();
            const afterClick = el.getAttribute('aria-checked') === 'true';
            if (afterClick !== wanted) {
              if (role === 'radio' && wanted) {
                const group = el.closest('[role="radiogroup"]') || el.parentElement || document;
                for (const sibling of group.querySelectorAll('[role="radio"]')) {
                  if (sibling !== el) sibling.setAttribute('aria-checked', 'false');
                }
              }
              el.setAttribute('aria-checked', String(wanted));
              el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
            }
            if ((el.getAttribute('aria-checked') === 'true') !== wanted) return { error: 'The page prevented this control from changing.' };
          }
          return { ok: true, changed: true, checked: wanted, target: agent.describe(el), approvalContextID: ticket.contextID };
        },

        inspect(id) {
          const el = agent.get(Number(id));
          const hints = [el.name, el.id, el.getAttribute('aria-label'), el.getAttribute('placeholder'), el.getAttribute('autocomplete')].join(' ');
          const sensitive = agent.sensitive(el) || isSensitiveName(hints);
          const attributes = [];
          for (const attr of Array.from(el.attributes || []).slice(0, 40)) {
            if (!/^aria-|^data-/i.test(attr.name)) continue;
            const redact = sensitive || isSensitiveName(attr.name) || isSensitiveName(attr.value);
            attributes.push({ name: clean(attr.name, 80), value: redact ? '[redacted]' : clean(attr.value, 160) });
          }
          const options = el instanceof HTMLSelectElement
            ? Array.from(el.options).slice(0, 100).map(option => ({
              text: sensitive ? '[redacted]' : clean(option.text, 160),
              value: sensitive ? '[redacted]' : clean(option.value, 160),
              selected: option.selected,
              disabled: option.disabled }))
            : [];
          const rect = el.getBoundingClientRect();
          let href = '';
          if (el instanceof HTMLAnchorElement && el.href) {
            try {
              const target = new URL(el.href);
              if (target.protocol === 'http:' || target.protocol === 'https:') {
                target.username = '';
                target.password = '';
                for (const key of Array.from(target.searchParams.keys())) {
                  if (isSensitiveName(key)) target.searchParams.set(key, '[redacted]');
                }
                href = clean(target.href, 2000);
              }
            } catch (_) {}
          }
          const rawValue = el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement
            ? el.value
            : el.isContentEditable ? el.innerText : '';
          const labelledBy = (el.getAttribute('aria-labelledby') || '').split(/\s+/)
            .map(labelID => labelID && document.getElementById(labelID)).filter(Boolean)
            .map(node => node.innerText).join(' ');
          const fromLabels = el.labels ? Array.from(el.labels).map(label => label.innerText).join(' ') : '';
          const inputButton = el instanceof HTMLInputElement && ['button', 'submit', 'reset'].includes((el.type || '').toLowerCase());
          const fullLabel = clean(
            el.getAttribute('aria-label') || labelledBy || fromLabels ||
            (inputButton ? el.value : '') || el.getAttribute('placeholder') || el.getAttribute('title') ||
            el.getAttribute('alt') || el.innerText || el.querySelector('img[alt]')?.getAttribute('alt') || el.getAttribute('name') || '', 500
          );
          return {
            id: Number(id),
            tag: el.tagName.toLowerCase(),
            role: agent.role(el),
            label: sensitive ? 'Sensitive field' : fullLabel,
            sensitive,
            value: sensitive ? '[redacted]' : clean(rawValue, 500),
            href,
            attributes,
            options,
            text: sensitive ? '' : clean(el.innerText || el.textContent || '', 500),
            rect: { x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height) },
            checked: el instanceof HTMLInputElement && ['checkbox', 'radio'].includes(el.type)
              ? el.checked
              : ['checkbox', 'radio', 'switch'].includes(agent.role(el))
                ? el.getAttribute('aria-checked') === 'true' : null,
            truncatedOptions: el instanceof HTMLSelectElement && el.options.length > 100,
            truncatedAttributes: (el.attributes || []).length > 40
          };
        },

        autofillFieldKey(el) {
          if (!(el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement)) return null;
          const type = el instanceof HTMLInputElement ? (el.type || 'text').toLowerCase() : '';
          if (el.matches(':disabled') || el.readOnly === true || el.getAttribute('aria-disabled') === 'true' ||
              el.getAttribute('aria-readonly') === 'true' || el.closest('[inert],[hidden],[aria-hidden="true"]') ||
              !agent.visible(el) || ['hidden', 'password', 'file', 'checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'range', 'color'].includes(type)) return null;
          const labelledBy = (el.getAttribute('aria-labelledby') || '').split(/\s+/)
            .map(id => id && document.getElementById(id)).filter(Boolean)
            .map(node => clean(node.innerText || node.textContent || '', 200)).join(' ');
          const fromLabels = el.labels ? Array.from(el.labels).slice(0, 10)
            .map(label => clean(label.innerText || label.textContent || '', 200)).join(' ') : '';
          const ownHints = [
            el.getAttribute('name'), el.id, el.getAttribute('aria-label'), el.getAttribute('placeholder'),
            el.getAttribute('title'), labelledBy, fromLabels
          ].filter(Boolean).join(' ').slice(0, 1_200);
          const form = el.form || el.closest('form');
          const formControls = form ? Array.from(form.elements || []).slice(0, 200) : [];
          const hiddenCSRFToken = field => field instanceof HTMLInputElement && field.type === 'hidden' &&
            /(?:^|[^a-z0-9])(?:csrf|xsrf)(?:$|[^a-z0-9])/i.test([
              field.getAttribute('name'), field.id, field.getAttribute('autocomplete'),
              field.getAttribute('aria-label'), field.getAttribute('placeholder')
            ].filter(Boolean).join(' '));
          const formLabels = form ? formControls.filter(node => !hiddenCSRFToken(node)).slice(0, 40).map(node => {
            const associated = node.labels ? Array.from(node.labels).slice(0, 4).map(label => label.innerText || '').join(' ') : '';
            return [node.getAttribute('aria-label'), node.getAttribute('placeholder'), associated].filter(Boolean).join(' ');
          }).join(' ').slice(0, 2_000) : '';
          const formHints = form ? [
            form.action, form.id, form.getAttribute('name'), form.getAttribute('aria-label'),
            form.getAttribute('autocomplete'), form.getAttribute('role'), formLabels
          ].filter(Boolean).join(' ').slice(0, 2_500) : '';
          const protectedPattern = new RegExp(
            '(?:passw|pwd|secret|token|credential|cookie|session|api.?key|card|cc-?num|cvv|cvc|csc|'
              + 'security.?code|expir|iban|routing|account.?num|ssn|social.?security|\\botp\\b|one.?time|'
              + 'sign[ -]?in|log[ -]?in|\\blogin\\b|\\bauth(?:enticate|entication|orize|orization)?\\b|'
              + '\\boauth\\b|\\bsso\\b|checkout|payment|billing)',
            'i');
          let authActionPath = false;
          if (form) {
            try {
              const path = new URL(form.getAttribute('action') || '', document.baseURI).pathname.toLowerCase();
              authActionPath = path.split('/').some(segment =>
                /^(?:auth|authenticate|authentication|authorize|authorization|oauth2?|sso|login|log-in|signin|sign-in)(?:[-_](?:callback|complete|continue|redirect|start))?$/.test(segment)
              );
            } catch (_) {}
          }
          const oversizedForm = Boolean(form && (form.elements?.length || 0) > 200);
          const controlHints = field => [
            field.getAttribute('name'), field.id, field.getAttribute('autocomplete'), field.getAttribute('aria-label'),
            field.getAttribute('placeholder'), field.labels ? Array.from(field.labels).slice(0, 4).map(label => label.innerText || '').join(' ') : ''
          ].filter(Boolean).join(' ').slice(0, 600);
          const formHasSensitiveControl = formControls.some(field => !hiddenCSRFToken(field) && (
            agent.sensitive(field) || protectedPattern.test(controlHints(field))
          ));
          const formLooksProtected = /sign[ -]?in|log[ -]?in|\blogin\b|\bauth(?:enticate|entication|orize|orization)?\b|\boauth\b|\bsso\b|checkout|payment|billing/i.test(formHints);
          const usernamePost = Boolean(form && (form.method || 'get').toLowerCase() === 'post' &&
            formControls.some(field => (field.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/).includes('username')));
          if (agent.sensitive(el) || protectedPattern.test(ownHints) || oversizedForm ||
              (form && (formHasSensitiveControl || authActionPath || usernamePost || formLooksProtected || protectedPattern.test(formHints)))) return null;

          const autocompleteTokens = (el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/).filter(Boolean);
          const autocompleteToken = autocompleteTokens.filter(token => !token.startsWith('section-') &&
            !['shipping', 'billing', 'home', 'work', 'mobile', 'fax', 'pager', 'on', 'off', 'webauthn'].includes(token)).pop() || '';
          const autocompleteMap = {
            name: 'fullName', 'given-name': 'givenName', 'additional-name': 'middleName', 'family-name': 'familyName',
            email: 'email', tel: 'phone', 'address-line1': 'addressLine1', 'address-line2': 'addressLine2',
            'address-level2': 'city', 'address-level1': 'region', 'postal-code': 'postalCode',
            country: 'country', 'country-name': 'country', organization: 'organization'
          };
          if (autocompleteMap[autocompleteToken]) return autocompleteMap[autocompleteToken];

          const hint = ownHints.toLowerCase().replace(/[\s.]+/g, '-');
          if (/address(?:-line)?-?2|address2|street2|apt(?:-number)?|suite|unit/.test(hint)) return 'addressLine2';
          if (/given-name|first(?:-|_)?name|fname/.test(hint)) return 'givenName';
          if (/middle(?:-|_)?name|additional(?:-|_)?name|mname/.test(hint)) return 'middleName';
          if (/family-name|last(?:-|_)?name|surname|lname/.test(hint)) return 'familyName';
          if (/full[-_]?name|name[-_]?full/.test(hint)) return 'fullName';
          if (/e-?mail/.test(hint)) return 'email';
          if (/phone|telephone|mobile|(^|[-_])tel($|[-_])/.test(hint)) return 'phone';
          if (/address(?:-line)?-?1|address1|street|(^|[-_])address($|[-_])/.test(hint)) return 'addressLine1';
          if (/(^|[-_])city($|[-_])|town/.test(hint)) return 'city';
          if (/state|province|region|county/.test(hint)) return 'region';
          if (/postal|zip/.test(hint)) return 'postalCode';
          if (/country/.test(hint)) return 'country';
          if (/organization|organisation|company|business/.test(hint)) return 'organization';
          if (/(^|[-_])name($|[-_])/.test(hint)) return 'fullName';
          return null;
        },

        autofillCandidates() {
          const nodes = Array.from(document.querySelectorAll('input,textarea,select')).slice(0, 500);
          const fields = [];
          const formSignature = form => form ? JSON.stringify([
            form.action, (form.method || 'get').toLowerCase(), form.id || '', form.getAttribute('name') || '',
            form.getAttribute('autocomplete') || '', form.getAttribute('role') || ''
          ]) : '';
          const fieldIdentity = el => {
            const labelledBy = (el.getAttribute('aria-labelledby') || '').split(/\s+/)
              .map(id => id && document.getElementById(id)).filter(Boolean)
              .map(node => clean(node.innerText || node.textContent || '', 200)).join(' ');
            const labels = el.labels ? Array.from(el.labels).slice(0, 10)
              .map(label => clean(label.innerText || label.textContent || '', 200)).join(' ') : '';
            const options = el instanceof HTMLSelectElement
              ? Array.from(el.options).slice(0, 40).map(option => [
                  option.value.slice(0, 100), clean(option.text, 100), Boolean(option.disabled),
                  Boolean(option.closest('optgroup')?.disabled)
                ])
              : [];
            return JSON.stringify({
              label: clean(agent.label(el), 500),
              ariaLabel: clean(el.getAttribute('aria-label'), 500),
              labelledBy: clean(labelledBy, 500),
              labels: clean(labels, 1_000),
              placeholder: clean(el.getAttribute('placeholder'), 300),
              title: clean(el.getAttribute('title'), 300),
              alt: clean(el.getAttribute('alt'), 300),
              optionsCount: el instanceof HTMLSelectElement ? el.options.length : 0,
              options
            });
          };
          for (const el of nodes) {
            const key = agent.autofillFieldKey(el);
            if (!key) continue;
            const form = el.form || el.closest('form');
            const signature = JSON.stringify([
              el.tagName, el instanceof HTMLInputElement ? (el.type || 'text').toLowerCase() : '',
              el.getAttribute('name') || '', el.id || '', el.getAttribute('autocomplete') || '',
              fieldIdentity(el), formSignature(form)
            ]);
            fields.push({ el, form, key, signature, id: agent.idFor(el) });
            if (fields.length >= 30) break;
          }
          return fields;
        },

        autofillPreviewMatches(preview) {
          if (!preview || preview.documentNonce !== agent.documentNonce) return false;
          const current = agent.autofillCandidates();
          if (current.length !== preview.fields.length) return false;
          return current.every((candidate, index) => {
            const expected = preview.fields[index];
            return candidate.el === expected.el && candidate.form === expected.form &&
              candidate.id === expected.id && candidate.key === expected.key && candidate.signature === expected.signature;
          });
        },

        previewAutofill(previewID, expectedDocumentNonce) {
          if (typeof previewID !== 'string' || !previewID || previewID.length > 100) return { error: 'The form preview could not be prepared.' };
          if (!expectedDocumentNonce || expectedDocumentNonce !== agent.documentNonce) return { error: 'The page changed before the form preview.' };
          const preview = { documentNonce: agent.documentNonce, fields: agent.autofillCandidates() };
          if (!agent.autofillPreviews) agent.autofillPreviews = new Map();
          if (agent.autofillPreviews.size >= 8) agent.autofillPreviews.clear();
          agent.autofillPreviews.set(previewID, preview);
          return { documentNonce: preview.documentNonce, fields: preview.fields.map(field => ({ id: field.id, key: field.key })) };
        },

        validateAutofillPreview(previewID, expectedDocumentNonce) {
          const preview = agent.autofillPreviews && agent.autofillPreviews.get(String(previewID || ''));
          if (!preview || expectedDocumentNonce !== agent.documentNonce || preview.documentNonce !== agent.documentNonce) {
            return { valid: false };
          }
          return { valid: agent.autofillPreviewMatches(preview) };
        },

        async fillAutofillPreview(previewID, profileValues, expectedDocumentNonce) {
          const previews = agent.autofillPreviews;
          const preview = previews && previews.get(String(previewID || ''));
          if (!preview || expectedDocumentNonce !== agent.documentNonce || preview.documentNonce !== agent.documentNonce) {
            return { error: 'The form changed. Take a fresh preview before filling.' };
          }
          if (!agent.autofillPreviewMatches(preview)) {
            previews.delete(String(previewID));
            return { error: 'The form fields changed after the preview. Review a fresh form before filling.' };
          }
          const values = profileValues && typeof profileValues === 'object' ? profileValues : {};
          const filledKeys = [];
          const skippedKeys = [];
          for (const field of preview.fields) {
            const value = values[field.key];
            if (typeof value !== 'string' || !value.trim()) continue;
            const el = field.el;
            if (!agent.autofillPreviewMatches(preview) || agent.autofillFieldKey(el) !== field.key ||
                !el.isConnected || el.matches(':disabled') || el.readOnly === true || el.closest('[inert]')) {
              previews.delete(String(previewID));
              return { error: 'The form changed before its approved fill could finish.' };
            }
            if (typeof el.focus === 'function') el.focus({ preventScroll: true });
            // Focus handlers can replace the target, turn it sensitive, or alter
            // the form. Re-evaluate the whole binding immediately before write.
            if (!agent.autofillPreviewMatches(preview) || agent.autofillFieldKey(el) !== field.key ||
                !el.isConnected || el.matches(':disabled') || el.readOnly === true ||
                el.getAttribute('aria-disabled') === 'true' || el.getAttribute('aria-readonly') === 'true' || el.closest('[inert]')) {
              previews.delete(String(previewID));
              return { error: 'The form changed when a field received focus. No further fields were filled.' };
            }

            let nextValue = value;
            if (el instanceof HTMLSelectElement) {
              const wanted = value.trim().toLocaleLowerCase();
              const options = Array.from(el.options);
              let countryNameForValue = null;
              let countryValueForName = null;
              if (field.key === 'country' && typeof Intl.DisplayNames === 'function') {
                try {
                  const displayNames = new Intl.DisplayNames(['en'], { type: 'region' });
                  if (/^[A-Za-z]{2,3}$/.test(value.trim())) countryNameForValue = displayNames.of(value.trim().toUpperCase())?.toLocaleLowerCase() || null;
                  for (const candidate of options) {
                    if (/^[A-Za-z]{2,3}$/.test(candidate.value.trim())) {
                      const display = displayNames.of(candidate.value.trim().toUpperCase());
                      if (display?.toLocaleLowerCase() === wanted) { countryValueForName = candidate.value; break; }
                    }
                  }
                } catch (_) {}
              }
              const option = options.find(candidate =>
                candidate.value.trim().toLocaleLowerCase() === wanted || candidate.text.trim().toLocaleLowerCase() === wanted ||
                (countryNameForValue && candidate.text.trim().toLocaleLowerCase() === countryNameForValue) ||
                (countryValueForName && candidate.value === countryValueForName)
              );
              if (!option || option.disabled || option.closest('optgroup')?.disabled) {
                skippedKeys.push(field.key);
                continue;
              }
              nextValue = option.value;
            }
            const prototype = el instanceof HTMLInputElement ? HTMLInputElement.prototype :
              el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLSelectElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
            if (!setter) {
              skippedKeys.push(field.key);
              continue;
            }
            setter.call(el, nextValue);
            el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            if (!agent.autofillPreviewMatches(preview) || agent.autofillFieldKey(el) !== field.key) {
              previews.delete(String(previewID));
              return { error: 'The form changed while it handled a filled field. Further filling stopped.' };
            }
            filledKeys.push(field.key);
          }
          previews.delete(String(previewID));
          return { ok: filledKeys.length > 0, filledKeys, skippedKeys };
        },

        scroll(direction) {
          const before = scrollY;
          window.scrollBy({ top: (direction === 'up' ? -1 : 1) * innerHeight * 0.8, behavior: 'instant' });
          const atEnd = innerHeight + scrollY >= document.documentElement.scrollHeight - 4;
          return { ok: true, moved: Math.round(scrollY - before), atTop: scrollY <= 0, atBottom: atEnd };
        },

        readText(offset, maxChars) {
          const root = document.querySelector('main, article, [role=main]') || document.body;
          const text = clean(root ? root.innerText : '', 2000000);
          return { total: text.length, offset, text: text.slice(offset, offset + maxChars) };
        },

        searchResults(max) {
          const limit = Math.max(0, Math.min(10, Math.floor(Number(max) || 5)));
          const seen = new Set();
          const results = [];
          for (const anchor of document.querySelectorAll('a[href]')) {
            if (results.length >= limit) break;
            const rawHref = anchor.getAttribute('href') || '';
            if (!/^(https?:)?\/\//i.test(rawHref)) continue;
            if (anchor.closest('[aria-hidden=true],[inert]')) continue;
            if (!agent.visible(anchor)) continue;
            const isResultAnchor = anchor.closest('h2,h3')
              || anchor.querySelector('h2,h3')
              || anchor.getAttribute('data-testid') === 'result-title-a';
            if (!isResultAnchor) continue;
            if (agent.sensitive(anchor)) continue;
            let url;
            try { url = new URL(rawHref, document.baseURI); } catch (_) { continue; }
            if (url.protocol !== 'http:' && url.protocol !== 'https:') continue;
            if (seen.has(url.href)) continue;
            seen.add(url.href);
            results.push({
              id: agent.idFor(anchor),
              title: clean(agent.label(anchor), 80),
              url: clean(url.host + url.pathname, 60)
            });
          }
          return { results };
        },

        // Resolves once the DOM has been quiet for `quietMs`, or at `timeoutMs`.
        settle(quietMs, timeoutMs) {
          return new Promise(resolve => {
            let last = Date.now();
            const observer = new MutationObserver(() => { last = Date.now(); });
            observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
            const start = Date.now();
            const timer = setInterval(() => {
              const now = Date.now();
              if (now - last >= quietMs || now - start >= timeoutMs) {
                clearInterval(timer);
                observer.disconnect();
                resolve({ quiet: now - last >= quietMs });
              }
            }, 100);
          });
        }
      };
      globalThis.__vxAgent = agent;
    }
    const agent = globalThis.__vxAgent;
    """#

    private static func script(_ body: String) -> String {
        bootstrap + "\nagent.setRedactions(typeof redactValues !== 'undefined' ? redactValues : []);\n"
            + "return JSON.stringify(await (async () => { " + body + " })());"
    }

    static let snapshot = script("return agent.snapshot(maxElements, maxText);")
    static let documentIdentity = script("return { nonce: agent.documentNonce };")
    static let click = script(
        "return await agent.click(id, confirmed, typeof approvalID === 'undefined' "
            + "? 'legacy:' + Math.random() : approvalID, "
            + "typeof confirmationContextID === 'undefined' ? null : confirmationContextID, "
            + "typeof expectedDocumentNonce === 'undefined' ? null : expectedDocumentNonce);"
    )
    static let type = script(
        "return await agent.type(id, text, submit, confirmed, typeof approvalID === 'undefined' "
            + "? 'legacy:' + Math.random() : approvalID, "
            + "typeof confirmationContextID === 'undefined' ? null : confirmationContextID, "
            + "typeof expectedDocumentNonce === 'undefined' ? null : expectedDocumentNonce);"
    )
    static let select = script("return await agent.select(id, option);")
    static let pressKey = script(
        "return await agent.pressKey(key, id, confirmed, "
            + "typeof expectedDocumentNonce === 'undefined' ? null : expectedDocumentNonce, "
            + "typeof approvalID === 'undefined' ? 'legacy:' + Math.random() : approvalID, "
            + "typeof confirmationContextID === 'undefined' ? null : confirmationContextID);"
    )
    static let setChecked = script(
        "return agent.setChecked(id, checked, confirmed, "
            + "typeof expectedDocumentNonce === 'undefined' ? null : expectedDocumentNonce, "
            + "typeof approvalID === 'undefined' ? 'legacy:' + Math.random() : approvalID, "
            + "typeof confirmationContextID === 'undefined' ? null : confirmationContextID);"
    )
    static let inspect = script("return agent.inspect(id);")
    static let previewAutofill = script("return agent.previewAutofill(previewID, expectedDocumentNonce);")
    static let validateAutofillPreview = script("return agent.validateAutofillPreview(previewID, expectedDocumentNonce);")
    static let fillAutofillPreview = script("return await agent.fillAutofillPreview(previewID, profileValues, expectedDocumentNonce);")
    static let scroll = script("return agent.scroll(direction);")
    static let readText = script("return agent.readText(offset, maxChars);")
    static let searchResults = script("return agent.searchResults(maxResults);")
    static let settle = script("return await agent.settle(quietMs, timeoutMs);")
    static let maskSensitiveForScreenshot = script(#"""
      if (expectedDocumentNonce && agent.documentNonce !== expectedDocumentNonce) return { error: 'The page changed before the screenshot.' };
      if (typeof captureOwner !== 'string' || !captureOwner || !Number.isSafeInteger(captureSequence) || captureSequence < 1) {
        return { error: 'The screenshot capture has no valid owner.' };
      }
      if (captureSequence < agent.screenshotMaskSequence) return { error: 'This screenshot capture is stale.', staleOwner: true };
      const existing = Array.isArray(agent.screenshotMask) ? agent.screenshotMask : [];
      if (existing.length) {
        if (captureSequence === agent.screenshotMaskSequence && agent.screenshotMaskOwner !== captureOwner) {
          return { error: 'This screenshot capture is stale.', staleOwner: true };
        }
        if (captureSequence === agent.screenshotMaskSequence && agent.screenshotMaskOwner === captureOwner) {
          return { error: 'This screenshot capture already owns the active mask.' };
        }
      }
      // Transfer original-style records when a newer capture takes ownership,
      // then scan for sensitive controls and frames added since the last one.
      const records = existing;
      const known = new Set(records.map(record => record.el));
      const previousCount = records.length;
      const targets = agent.collect(document, []);
      // Cross-origin frames cannot be inspected by the isolated world. Hide the
      // frame surface during capture so a payment/sign-in form inside it cannot
      // leak its visible values into the image.
      document.querySelectorAll('iframe,frame').forEach(frame => targets.push(frame));
      for (const el of new Set(targets)) {
        if (!agent.sensitive(el) && !['IFRAME', 'FRAME'].includes(el.tagName)) continue;
        const style = el.style;
        if (!known.has(el)) {
          records.push({
            el,
            hadStyle: el.hasAttribute('style'),
            visibility: style.getPropertyValue('visibility'),
            priority: style.getPropertyPriority('visibility')
          });
          known.add(el);
        }
        // A site may have changed an earlier mask while the previous capture
        // owned the page. Reassert the mask without replacing its first style
        // record, so only the newest owner can restore the true original.
        style.setProperty('visibility', 'hidden', 'important');
      }
      agent.screenshotMask = records;
      agent.screenshotMaskOwner = captureOwner;
      agent.screenshotMaskSequence = captureSequence;
      return {
        masked: records.length,
        added: records.length - previousCount,
        ...(previousCount ? { ownershipTransferred: true } : {})
      };
    """#)
    static let restoreScreenshotMask = script(#"""
      if (expectedDocumentNonce && agent.documentNonce !== expectedDocumentNonce) return { restored: 0 };
      if (typeof captureOwner !== 'string' || !captureOwner || agent.screenshotMaskOwner !== captureOwner) {
        return { restored: 0, staleOwner: true };
      }
      const records = Array.isArray(agent.screenshotMask) ? agent.screenshotMask : [];
      for (const record of records) {
        const { el } = record;
        if (!el || !el.isConnected) continue;
        if (record.visibility) el.style.setProperty('visibility', record.visibility, record.priority || '');
        else el.style.removeProperty('visibility');
        if (!record.hadStyle && !(el.getAttribute('style') || '').trim()) el.removeAttribute('style');
      }
      agent.screenshotMask = [];
      agent.screenshotMaskOwner = null;
      return { restored: records.length };
    """#)
}
