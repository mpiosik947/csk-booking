import test from 'node:test';import assert from 'node:assert/strict';import sharp from 'sharp';
import {normalizePartnerImage,PARTNER_UPLOAD_LIMIT} from './tenant-partner-media.ts';
for(const format of ['png','jpeg','webp'])test('decode and normalize '+format+' without metadata',async()=>{
 const source=await sharp({create:{width:120,height:60,channels:4,background:'#448844'}})[format]().withMetadata().toBuffer();
 const result=await normalizePartnerImage(source,'image/'+format),meta=await sharp(result.bytes).metadata();
 assert.equal(meta.format,'webp');assert.equal(meta.width,120);assert.equal(meta.height,60);assert.equal(meta.exif,undefined);assert.equal(meta.icc,undefined);assert.equal(meta.xmp,undefined);
});
test('SVG loader is blocked even when a valid SVG is disguised as PNG',async()=>{
 const svg=Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><rect width="20" height="20" fill="red"/></svg>');
 await assert.rejects(sharp(svg).metadata(),/blocked|disabled|unsupported image format/i);
 await assert.rejects(normalizePartnerImage(svg,'image/png'));
 await assert.rejects(normalizePartnerImage(Buffer.from('<!doctype html><html><body>not an image</body></html>'),'image/png'));
});
test('reject animated WebP and dimension limit independently of the pixel limit',async()=>{
 const pixels=Buffer.concat([Buffer.alloc(20*20*3,0),Buffer.alloc(20*20*3,255)]);
 const animated=await sharp(pixels,{raw:{width:20,height:40,pageHeight:20,channels:3}}).webp({loop:0,delay:[100,100]}).toBuffer();
 assert.equal((await sharp(animated,{animated:true}).metadata()).pages,2);
 await assert.rejects(normalizePartnerImage(animated,'image/webp'));
 const wide=await sharp({create:{width:8001,height:1,channels:3,background:'white'}}).png().toBuffer();
 await assert.rejects(normalizePartnerImage(wide,'image/png'));
});
test('large allowed raster is resized within bounded stripped WebP output',async()=>{
 const source=await sharp({create:{width:3000,height:1500,channels:3,background:'blue'}}).jpeg().withMetadata().toBuffer();
 const result=await normalizePartnerImage(source,'image/jpeg'),meta=await sharp(result.bytes).metadata();
 assert.equal(result.width,2400);assert.equal(result.height,1200);assert.equal(meta.format,'webp');assert.ok(result.bytes.length<=1024*1024);assert.equal(meta.exif,undefined);assert.equal(meta.icc,undefined);
});
test('reject unsafe, spoofed, truncated, oversized and excessive-pixel images',async()=>{
 for(const [bytes,type]of [[Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"><script>x</script></svg>'),'image/svg+xml'],[Buffer.from('<svg/>'),'image/png'],[Buffer.from('RIFFfakeWEBP'),'image/webp'],[Buffer.alloc(PARTNER_UPLOAD_LIMIT+1),'image/png']])await assert.rejects(normalizePartnerImage(bytes,type));
 const png=await sharp({create:{width:20,height:20,channels:3,background:'red'}}).png().toBuffer();await assert.rejects(normalizePartnerImage(png,'image/jpeg'));
 await assert.rejects(normalizePartnerImage(png.subarray(0,40),'image/png'));
 const huge=await sharp({create:{width:5000,height:5000,channels:3,background:'white'}}).png().toBuffer();await assert.rejects(normalizePartnerImage(huge,'image/png'));
});
