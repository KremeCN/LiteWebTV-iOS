const assert = require('assert');

function bandwidthValue(inf) {
    const match = inf.match(/BANDWIDTH=(\d+)/);
    return match ? Number(match[1]) : 0;
}

function selectHighestVariant(master, masterURL) {
    const lines = master.split('\n');
    let bestBandwidth = -1;
    let bestURI = null;
    for (let i = 0; i < lines.length; i++) {
        const trimmed = lines[i].trim();
        if (!trimmed.startsWith('#EXT-X-STREAM-INF:')) continue;
        const bandwidth = bandwidthValue(trimmed);
        let uri = '';
        for (let j = i + 1; j < lines.length; j++) {
            const candidate = lines[j].trim();
            if (!candidate || candidate.startsWith('#')) continue;
            uri = candidate;
            break;
        }
        if (uri && bandwidth >= bestBandwidth) {
            bestBandwidth = bandwidth;
            bestURI = uri;
        }
    }
    return bestURI ? new URL(bestURI, masterURL).href : null;
}

function rewriteMediaPlaylist(playlist, mediaURL, proxy) {
    return playlist.split('\n').map((raw) => {
        const trimmed = raw.trim();
        if (trimmed.startsWith('#EXT-X-KEY:') || trimmed.startsWith('#EXT-X-MAP:')) {
            return trimmed.replace(/URI="([^"]+)"/, (_, uri) => `URI="${proxy(new URL(uri, mediaURL).href)}"`);
        }
        if (!trimmed || trimmed.startsWith('#')) return raw;
        return proxy(new URL(trimmed, mediaURL).href);
    }).join('\n');
}

const master = `#EXTM3U
#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=900000,RESOLUTION=854x480
/ldncctvwbcd/cdrmldcctv1_1_480P/playlist.m3u8?wsApp=HLS
#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=3200000,RESOLUTION=1920x1080
/ldncctvwbcd/cdrmldcctv1_1_1080P/playlist.m3u8?wsApp=HLS
#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=600000,RESOLUTION=640x360
/ldncctvwbcd/cdrmldcctv1_1_360P/playlist.m3u8?wsApp=HLS
`;

const base = 'https://ldncctvwbcdcnc.v.wscdns.com/ldncctvwbcd/cdrmldcctv1_1/index.m3u8?b=200-4000';
const selected = selectHighestVariant(master, base);
assert.ok(selected.includes('1080P'), selected);

const media = `#EXTM3U
#EXT-X-TARGETDURATION:2
#EXTINF:2.000,
seg1.ts
#EXTINF:2.000,
https://cdn.example/seg2.ts
`;
const rewritten = rewriteMediaPlaylist(media, 'https://cdn.example/live/media.m3u8', (u) => `/seg.ts?u=${u}`);
assert.ok(rewritten.includes('/seg.ts?u=https://cdn.example/live/seg1.ts'), rewritten);
assert.ok(rewritten.includes('/seg.ts?u=https://cdn.example/seg2.ts'), rewritten);

const keyed = `#EXTM3U
#EXT-X-KEY:METHOD=NONE,URI="key.bin"
#EXTINF:2.000,
seg.ts
`;
const keyedOut = rewriteMediaPlaylist(keyed, 'https://cdn.example/live/media.m3u8', (u) => `/seg.ts?u=${u}`);
assert.ok(keyedOut.includes('URI="/seg.ts?u=https://cdn.example/live/key.bin"'), keyedOut);

const mediaOnly = `#EXTM3U
#EXT-X-TARGETDURATION:2
#EXTINF:2.000,
https://cdn.example/a.ts
`;
assert.strictEqual(selectHighestVariant(mediaOnly, base), null);

console.log('cctv_hls_rewrite tests passed');
