'use strict';

const assert = require('assert');
const https = require('https');
const { URL } = require('url');

const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1';

const STREAMS = {
    cctv1: 'https://ldncctvwbcdcnc.v.wscdns.com/ldncctvwbcd/cdrmldcctv1_1/index.m3u8?b=200-4000',
    cctv3: 'https://ldocctvwbcdks.v.kcdnvip.com/ldocctvwbcd/cdrmldcctv3_1/index.m3u8?b=200-4000',
    cctv6: 'https://ldocctvwbcdbd.a.bdydns.com/ldocctvwbcd/cdrmldcctv6_1/index.m3u8?b=200-4000',
    cctv8: 'https://ldocctvwbcdks.v.kcdnvip.com/ldocctvwbcd/cdrmldcctv8_1/index.m3u8?b=200-4000',
};

function get(urlString, binary = false) {
    return new Promise((resolve, reject) => {
        const url = new URL(urlString);
        const req = https.request(url, {
            headers: {
                'User-Agent': UA,
                Referer: 'https://tv.cctv.com/live/cctv1/',
                Origin: 'https://tv.cctv.com',
                Accept: '*/*',
            },
        }, (res) => {
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('end', () => {
                const buf = Buffer.concat(chunks);
                if (res.statusCode < 200 || res.statusCode >= 300) {
                    reject(new Error(`${urlString} -> ${res.statusCode}`));
                    return;
                }
                resolve(binary ? buf : buf.toString('utf8'));
            });
        });
        req.setTimeout(15000, () => req.destroy(new Error('timeout ' + urlString)));
        req.on('error', reject);
        req.end();
    });
}

function highestVariant(master, masterURL) {
    let best = -1;
    let uri = null;
    const lines = master.split('\n');
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i].trim();
        if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
        const match = line.match(/BANDWIDTH=(\d+)/);
        const bw = match ? Number(match[1]) : 0;
        let next = '';
        for (let j = i + 1; j < lines.length; j++) {
            const candidate = lines[j].trim();
            if (!candidate || candidate.startsWith('#')) continue;
            next = candidate;
            break;
        }
        if (next && bw >= best) {
            best = bw;
            uri = next;
        }
    }
    return uri ? new URL(uri, masterURL).href : null;
}

function firstSegment(playlist, mediaURL) {
    for (const raw of playlist.split('\n')) {
        const line = raw.trim();
        if (!line || line.startsWith('#')) continue;
        return new URL(line, mediaURL).href;
    }
    return null;
}

(async () => {
    for (const [slug, masterURL] of Object.entries(STREAMS)) {
        const master = await get(masterURL);
        assert.ok(master.includes('#EXTM3U'), slug + ' master');
        assert.ok(master.includes('#EXT-X-STREAM-INF'), slug + ' variants');
        const variant = highestVariant(master, masterURL);
        assert.ok(variant, slug + ' highest variant');
        const media = await get(variant);
        assert.ok(media.includes('#EXTINF'), slug + ' media');
        const seg = firstSegment(media, variant);
        assert.ok(seg, slug + ' segment url');
        const ts = await get(seg, true);
        assert.ok(ts.length >= 188, slug + ' ts length');
        assert.strictEqual(ts[0], 0x47, slug + ' ts sync');
        console.log(slug, 'ok', 'variant=' + variant.split('/').pop(), 'ts=' + ts.length);
    }
    console.log('cctv_native_cdn_probe passed (encrypted TS present; decrypt needs iOS worker)');
})().catch((err) => {
    console.error(err);
    process.exit(1);
});
