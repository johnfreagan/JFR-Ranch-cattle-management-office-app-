// Post-edit gate required by CLAUDE.md: the big <script> block must parse,
// and <div> tags must balance outside script/style. No node on this machine,
// so this runs on JavaScriptCore via `osascript -l JavaScript`.
ObjC.import('Foundation');

function readFile(path) {
    var s = $.NSString.stringWithContentsOfFileEncodingError(
        path, $.NSUTF8StringEncoding, null);
    return ObjC.unwrap(s);
}

function run(argv) {
    var path = argv[0] || 'index.html';
    var html = readFile(path);
    if (!html) { console.log('FAIL: could not read ' + path); return 'FAIL'; }

    var out = [];
    var ok = true;

    // 1. every <script> block must parse
    var re = /<script\b[^>]*>([\s\S]*?)<\/script>/g, m, blocks = [];
    while ((m = re.exec(html)) !== null) blocks.push(m[1]);
    var largest = 0;
    blocks.forEach(function (b, i) {
        if (b.length > largest) largest = b.length;
        if (!b.trim()) return;
        try { new Function(b); }
        catch (e) { ok = false; out.push('PARSE FAIL in script block ' + i + ': ' + e.message); }
    });
    out.push('script blocks: ' + blocks.length + ', largest ' + largest + ' chars — ' +
             (ok ? 'all parse OK' : 'PARSE ERRORS'));

    // 2. div balance outside script/style
    var stripped = html
        .replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, '')
        .replace(/<style\b[^>]*>[\s\S]*?<\/style>/g, '')
        .replace(/<!--[\s\S]*?-->/g, '');
    var opens = (stripped.match(/<div\b/g) || []).length;
    var closes = (stripped.match(/<\/div>/g) || []).length;
    if (opens !== closes) ok = false;
    out.push('divs: ' + opens + ' open / ' + closes + ' close — ' +
             (opens === closes ? 'BALANCED' : 'UNBALANCED'));

    out.push(ok ? 'RESULT: PASS' : 'RESULT: FAIL');
    console.log(out.join('\n'));
    return ok ? 'PASS' : 'FAIL';
}
