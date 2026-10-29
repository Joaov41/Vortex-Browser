import Foundation

/// Read-only scripts for extracting visible links and actual HTML tables.
enum BrowserAgentExtractionScript {
    static let links = #"""
    const MAX_LINKS = 80;
    const MAX_LINK_TEXT = 240;
    const MAX_URL = 2000;
    const MAX_CHARACTERS = 42000;
    const sensitiveNames = new Set([
      'access_token', 'id_token', 'token', 'auth', 'authorization', 'code', 'password', 'passwd',
      'secret', 'client_secret', 'api_key', 'apikey', 'key', 'credential', 'credentials',
      'session', 'sessionid', 'signature', 'sig', 'jwt'
    ]);
    const redactionValues = (typeof redactValues !== 'undefined' && Array.isArray(redactValues) ? redactValues : [])
      .map(value => String(value || '')).filter(value => value.length >= 2)
      .sort((a, b) => b.length - a.length);
    function redactText(text) {
      let out = String(text ?? '');
      for (const value of redactionValues) {
        if (value) out = out.split(value).join('[redacted]');
      }
      return out;
    }

    function safeURL(raw) {
      try {
        const url = new URL(raw, document.baseURI);
        if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
        url.username = '';
        url.password = '';
        url.hash = '';
        for (const key of Array.from(url.searchParams.keys())) {
          const normalized = key.toLowerCase().replace(/-/g, '_');
          if (sensitiveNames.has(normalized) || /_(token|secret|password|credential)$/.test(normalized)) {
            url.searchParams.set(key, '[redacted]');
          }
        }
        const value = url.href;
        return value.length <= MAX_URL ? value : null;
      } catch (_) { return null; }
    }

    function visible(element) {
      for (let node = element; node && node.nodeType === 1; node = node.parentElement) {
        if (node.hasAttribute('hidden') || node.hasAttribute('inert') ||
            node.getAttribute('aria-hidden') === 'true') return false;
        const style = window.getComputedStyle(node);
        if (style.display === 'none' || style.visibility === 'hidden' ||
            style.visibility === 'collapse' || Number(style.opacity) === 0) return false;
      }
      return true;
    }

    function visibleText(root, owningTable) {
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      const pieces = [];
      let node;
      while ((node = walker.nextNode())) {
        const parent = node.parentElement;
        if (!parent || parent.closest('script,style,template,noscript,input,textarea,select,option,button,[hidden],[aria-hidden="true"],[inert]')) continue;
        if (owningTable && parent.closest('table') !== owningTable) continue;
        if (!visible(parent)) continue;
        const value = (node.nodeValue || '').replace(/\s+/g, ' ').trim();
        if (value) pieces.push(value);
      }
      return redactText(pieces.join(' ').replace(/\s+/g, ' ').trim());
    }

    const rawPageTitle = document.title || '';
    const pageTitle = redactText(rawPageTitle).slice(0, 300);
    const pageURL = safeURL(location.href) || location.origin + location.pathname;
    const anchors = Array.from(document.querySelectorAll('a[href]')).filter(visible);
    const links = [];
    const reasons = [];
    let truncated = anchors.length > MAX_LINKS || rawPageTitle.length > pageTitle.length;
    if (anchors.length > MAX_LINKS) reasons.push('link_count_limit');
    if (rawPageTitle.length > pageTitle.length) reasons.push('page_title_limit');
    let usedCharacters = pageTitle.length + pageURL.length;

    for (const anchor of anchors) {
      if (String(anchor.href || '').length > MAX_URL) {
        truncated = true;
        if (!reasons.includes('link_url_limit')) reasons.push('link_url_limit');
        continue;
      }
      const url = safeURL(anchor.href);
      if (!url) continue;
      const rawText = visibleText(anchor, null);
      const normalizedTitle = redactText((anchor.getAttribute('title') || '').replace(/\s+/g, ' ').trim());
      const text = rawText.slice(0, MAX_LINK_TEXT);
      const title = normalizedTitle.slice(0, MAX_LINK_TEXT);
      if (rawText.length > text.length || normalizedTitle.length > title.length) {
        truncated = true;
        if (!reasons.includes('link_text_limit')) reasons.push('link_text_limit');
      }
      const cost = text.length + title.length + url.length;
      if (links.length >= MAX_LINKS || usedCharacters + cost > MAX_CHARACTERS) {
        truncated = true;
        if (!reasons.includes('dataset_character_limit')) reasons.push('dataset_character_limit');
        break;
      }
      links.push({ text, title, url });
      usedCharacters += cost;
    }

    return JSON.stringify({
      title: pageTitle,
      url: pageURL,
      totalLinks: anchors.length,
      returnedLinks: links.length,
      truncated,
      truncationReasons: reasons,
      links
    });
    """#

    static let tables = #"""
    const MAX_TABLES = 8;
    const MAX_ROWS = 100;
    const MAX_COLUMNS = 16;
    const MAX_CELL_TEXT = 400;
    const MAX_CHARACTERS = 72000;
    const sensitiveNames = new Set([
      'access_token', 'id_token', 'token', 'auth', 'authorization', 'code', 'password', 'passwd',
      'secret', 'client_secret', 'api_key', 'apikey', 'key', 'credential', 'credentials',
      'session', 'sessionid', 'signature', 'sig', 'jwt'
    ]);

    function safeURL(raw) {
      try {
        const url = new URL(raw, document.baseURI);
        if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
        url.username = '';
        url.password = '';
        url.hash = '';
        for (const key of Array.from(url.searchParams.keys())) {
          const normalized = key.toLowerCase().replace(/-/g, '_');
          if (sensitiveNames.has(normalized) || /_(token|secret|password|credential)$/.test(normalized)) {
            url.searchParams.set(key, '[redacted]');
          }
        }
        return url.href;
      } catch (_) { return null; }
    }
    const redactionValues = (typeof redactValues !== 'undefined' && Array.isArray(redactValues) ? redactValues : [])
      .map(value => String(value || '')).filter(value => value.length >= 2)
      .sort((a, b) => b.length - a.length);
    function redactText(text) {
      let out = String(text ?? '');
      for (const value of redactionValues) {
        if (value) out = out.split(value).join('[redacted]');
      }
      return out;
    }

    function visible(element) {
      for (let node = element; node && node.nodeType === 1; node = node.parentElement) {
        if (node.hasAttribute('hidden') || node.hasAttribute('inert') ||
            node.getAttribute('aria-hidden') === 'true') return false;
        const style = window.getComputedStyle(node);
        if (style.display === 'none' || style.visibility === 'hidden' ||
            style.visibility === 'collapse' || Number(style.opacity) === 0) return false;
      }
      return true;
    }

    function visibleText(root, owningTable) {
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      const pieces = [];
      let node;
      while ((node = walker.nextNode())) {
        const parent = node.parentElement;
        if (!parent || parent.closest('script,style,template,noscript,input,textarea,select,option,button,[hidden],[aria-hidden="true"],[inert]')) continue;
        if (parent.closest('table') !== owningTable || !visible(parent)) continue;
        const value = (node.nodeValue || '').replace(/\s+/g, ' ').trim();
        if (value) pieces.push(value);
      }
      return redactText(pieces.join(' ').replace(/\s+/g, ' ').trim());
    }

    const rawPageTitle = document.title || '';
    const pageTitle = redactText(rawPageTitle).slice(0, 300);
    const pageURL = safeURL(location.href) || location.origin + location.pathname;
    const visibleTables = Array.from(document.querySelectorAll('table')).filter(visible);
    const tables = [];
    const reasons = [];
    let usedCharacters = pageTitle.length + pageURL.length;
    let truncated = visibleTables.length > MAX_TABLES;
    if (truncated) reasons.push('table_count_limit');
    if (rawPageTitle.length > pageTitle.length) {
      truncated = true;
      reasons.push('page_title_limit');
    }

    for (let index = 0; index < visibleTables.length && tables.length < MAX_TABLES; index++) {
      const table = visibleTables[index];
      const allRows = Array.from(table.rows).filter(row => row.closest('table') === table && visible(row));
      if (!allRows.length) continue;
      const caption = Array.from(table.children).find(child => child.tagName.toLowerCase() === 'caption');
      const rawTableTitle = caption && visible(caption) ? visibleText(caption, table) : '';
      const tableTitle = rawTableTitle.slice(0, 240);
      const headerRow = allRows.find(row => row.parentElement && row.parentElement.tagName.toLowerCase() === 'thead') ||
        (allRows[0].querySelector('th') ? allRows[0] : null);
      const tableReasons = [];
      if (rawTableTitle.length > tableTitle.length) tableReasons.push('table_title_limit');
      const allHeaderCells = headerRow ? Array.from(headerRow.cells) : [];
      if (allHeaderCells.length > MAX_COLUMNS) tableReasons.push('column_limit');
      const rawHeaders = allHeaderCells.slice(0, MAX_COLUMNS).map(cell => {
        const rawValue = visibleText(cell, table);
        const value = rawValue.slice(0, MAX_CELL_TEXT);
        if (rawValue.length > value.length) tableReasons.push('header_text_limit');
        return value;
      });
      const sourceRows = allRows.filter(row => row !== headerRow);
      const rows = [];
      const hasSpans = allRows.some(row => Array.from(row.cells).some(cell => cell.colSpan > 1 || cell.rowSpan > 1));
      const layoutNote = hasSpans ? 'This table uses colspan or rowspan. Values are retained in source cell order; column alignment is not normalized.' : null;
      if (hasSpans) tableReasons.push('table_spans_unaligned');
      let tableTruncated = sourceRows.length > MAX_ROWS || tableReasons.length > 0;
      let localCharacters = tableTitle.length + rawHeaders.reduce((sum, value) => sum + value.length, 0);
      const rowLimit = Math.min(sourceRows.length, MAX_ROWS);
      for (let rowIndex = 0; rowIndex < rowLimit; rowIndex++) {
        const allCells = Array.from(sourceRows[rowIndex].cells);
        const cells = allCells.slice(0, MAX_COLUMNS);
        if (allCells.length > MAX_COLUMNS) {
          tableTruncated = true;
          if (!tableReasons.includes('column_limit')) tableReasons.push('column_limit');
        }
        const row = [];
        let rowCharacters = 0;
        let rowFits = true;
        for (const cell of cells) {
          const rawValue = visibleText(cell, table);
          const value = rawValue.slice(0, MAX_CELL_TEXT);
          if (rawValue.length > value.length) {
            tableTruncated = true;
            if (!tableReasons.includes('cell_text_limit')) tableReasons.push('cell_text_limit');
          }
          if (usedCharacters + localCharacters + rowCharacters + value.length > MAX_CHARACTERS) {
            truncated = true;
            tableTruncated = true;
            rowFits = false;
            reasons.push('dataset_character_limit');
            break;
          }
          row.push(value);
          rowCharacters += value.length;
        }
        if (rowFits && row.length) {
          rows.push(row);
          localCharacters += rowCharacters;
        }
        if (usedCharacters + localCharacters >= MAX_CHARACTERS ||
            reasons.includes('dataset_character_limit')) break;
      }
      if (sourceRows.length > MAX_ROWS) {
        tableReasons.push('row_limit');
        reasons.push('row_limit');
      }
      for (const reason of tableReasons) if (!reasons.includes(reason)) reasons.push(reason);
      if (tableTruncated && !tableReasons.length) tableReasons.push('table_extraction_limit');
      tables.push({
        index,
        title: tableTitle,
        layoutNote,
        headers: rawHeaders,
        rows,
        totalRows: sourceRows.length,
        totalColumns: Math.max(rawHeaders.length, ...sourceRows.map(row => row.cells.length), 0),
        truncated: tableTruncated,
        truncationReasons: Array.from(new Set(tableReasons))
      });
      usedCharacters += localCharacters;
      if (usedCharacters >= MAX_CHARACTERS) {
        truncated = true;
        if (!reasons.includes('dataset_character_limit')) reasons.push('dataset_character_limit');
        break;
      }
    }

    return JSON.stringify({
      title: pageTitle,
      url: pageURL,
      totalTables: visibleTables.length,
      returnedTables: tables.length,
      truncated,
      truncationReasons: Array.from(new Set(reasons)),
      tables
    });
    """#
}
