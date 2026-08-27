// Pure-logic tests for the Inventory (medicine FIFO) module.
//
// These cover the arithmetic that decides money and shrink, without a
// database or a browser: the Cowork paste parser, and the count sheet's
// "blank is not zero" rule. Everything else in the module is I/O.
//
// No node on this machine, so this runs on JavaScriptCore:
//     osascript -l JavaScript scripts/test-inventory.jxa.js index.html
//
// The functions are lifted out of index.html by name rather than copied,
// so the test cannot drift from the shipped code the way a copy would.
ObjC.import('Foundation');

function readFile(path) {
    var s = $.NSString.stringWithContentsOfFileEncodingError(
        path, $.NSUTF8StringEncoding, null);
    return ObjC.unwrap(s);
}

// Pull `function name(...) { ... }` out of the source by brace matching.
function grab(html, name) {
    var i = html.indexOf('function ' + name + '(');
    if (i < 0) throw new Error('function not found in index.html: ' + name);
    var depth = 0, j = html.indexOf('{', i);
    for (var k = j; k < html.length; k++) {
        if (html[k] === '{') depth++;
        else if (html[k] === '}') { depth--; if (depth === 0) return html.slice(i, k + 1); }
    }
    throw new Error('unbalanced braces reading ' + name);
}

function run(argv) {
    var path = argv[0] || 'index.html';
    var html = readFile(path);
    if (!html) { console.log('FAIL: could not read ' + path); return 'FAIL'; }

    var src = grab(html, 'invNum') + '\n' +
              grab(html, 'parseInvPasteBlock') + '\n' +
              grab(html, 'invCountedUnits');
    var mod = new Function(src + '; return { parseInvPasteBlock: parseInvPasteBlock, invCountedUnits: invCountedUnits };')();

    var out = [], ok = true;
    function t(name, cond) {
        if (!cond) ok = false;
        out.push((cond ? '  ok   ' : '  FAIL ') + name);
    }

    // ---- the Cowork paste block ------------------------------------------
    var r = mod.parseInvPasteBlock(
        'Vet Supply\t2026-09-04\tINV-88213\n' +
        'Draxxin\t2\t496.31\n' +
        'Ultrachoice 8\t4\t189.87\n' +
        'Valcor\t6\t150.71');
    t('header: vendor',                 r.header.vendor === 'Vet Supply');
    t('header: date',                   r.header.date === '2026-09-04');
    t('header: invoice number',         r.header.invoice_number === 'INV-88213');
    t('three product lines',            r.lines.length === 3);
    t('multi-word name kept whole',     r.lines[1].name === 'Ultrachoice 8');
    t('bottles parsed',                 r.lines[0].bottles === 2);
    t('price parsed',                   r.lines[0].price === 496.31);

    r = mod.parseInvPasteBlock('Vet Supply   2026-09-04   INV-9\nDraxxin   2   496.31');
    t('runs of spaces parse too',       r.lines.length === 1 && r.lines[0].price === 496.31);

    r = mod.parseInvPasteBlock('Draxxin\t2\t496.31\nValcor\t1\t150.71');
    t('headerless paste keeps line 1',  r.lines.length === 2 && r.lines[0].name === 'Draxxin');

    r = mod.parseInvPasteBlock('Vet Supply\t2026-09-04\nSubtotal:\nDraxxin\t2\t496.31');
    t('junk line ignored, not booked',  r.lines.length === 1 && r.unmatched.length === 1);

    // ---- the count sheet -------------------------------------------------
    // This is the one that matters. Number('') is 0, and a blank line read as
    // a count of zero would post an adjustment writing the stock to nothing.
    t('blank means NOT COUNTED',
        mod.invCountedUnits({ full_bottles: '', open_units: '', bottle_size: 500 }) === null);
    t('an explicit 0 IS a count of zero',
        mod.invCountedUnits({ full_bottles: '0', open_units: '', bottle_size: 500 }) === 0);
    t('2 full bottles + 400 open = 1400',
        mod.invCountedUnits({ full_bottles: '2', open_units: '400', bottle_size: 500 }) === 1400);
    t('an open bottle alone counts',
        mod.invCountedUnits({ full_bottles: '', open_units: '250', bottle_size: 500 }) === 250);

    out.push(ok ? 'RESULT: PASS' : 'RESULT: FAIL');
    console.log(out.join('\n'));
    return ok ? 'PASS' : 'FAIL';
}
