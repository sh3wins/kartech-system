/* =====================================================================
   KARTECH: the QR code for a client's Order Room
   - KQR.make(link)  → a QR code (the drawing is done by qrcode-generator)
   - KQR.share(info) → makes a picture card and opens "Share" (phone)
                       or downloads it (computer)
   - KQR.wa(info)    → a WhatsApp link with the client's message typed
   ===================================================================== */
window.KQR = (() => {
  let lib = null;
  const load = () => lib || (lib = new Promise((ok, no) => {
    if (window.qrcode) return ok(window.qrcode);
    const sc = document.createElement('script');
    sc.src = 'https://cdnjs.cloudflare.com/ajax/libs/qrcode-generator/1.4.4/qrcode.min.js';
    sc.onload = () => ok(window.qrcode);
    sc.onerror = () => { lib = null; no(new Error('Could not load the QR maker. Check the internet.')); };
    document.head.appendChild(sc);
  }));

  async function make(link){ const q = (await load())(0, 'M'); q.addData(link); q.make(); return q; }

  const first = name => String(name || '').trim().split(/\s+/)[0] || '';
  const phone = text => { const d = String(text || '').match(/(?:\+?254|0)\s?[17]\d{2}\s?\d{3}\s?\d{3}/); return d ? d[0].replace(/\D/g, '').replace(/^0/, '254') : ''; };

  function wa(info){
    const hi = first(info.customer) ? `Hi ${first(info.customer)}, ` : 'Hi, ';
    const txt = `${hi}this is your Kartech order room for ${info.ref}: ${info.link}\nSend us photos, ask questions and approve your design there.`;
    return 'https://wa.me/' + phone(info.customer + ' ' + (info.notes || '')) + '?text=' + encodeURIComponent(txt);
  }

  // shorten text until it fits the width
  function fit(ctx, text, max){ let t = String(text || ''); if (ctx.measureText(t).width <= max) return t;
    while (t.length > 1 && ctx.measureText(t + '…').width > max) t = t.slice(0, -1); return t + '…'; }
  function round(ctx, x, y, w, h, r){ ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r); ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath(); }

  // the picture: 1080 × 1350, good for WhatsApp and for printing
  async function card(info){
    const q = await make(info.link);
    try { await document.fonts.ready; } catch (e) {}
    const W = 1080, H = 1350, FONT = '"Archivo", "DM Sans", "Manrope", "Inter", system-ui, sans-serif';
    const forest = '#1F3A2A', ink = '#141A15', muted = '#5E6A62';
    const c = document.createElement('canvas'); c.width = W; c.height = H; const x = c.getContext('2d');

    x.fillStyle = '#F4F3EE'; x.fillRect(0, 0, W, H);
    x.fillStyle = forest; x.fillRect(0, 0, W, 330);

    // logo + name
    x.save(); x.translate(80, 64); x.scale(1.5, 1.5); x.fillStyle = '#fff';
    x.fill(new Path2D('M6 4h8v13L26 4h10L22 19l15 17H26L14 22v14H6z')); x.restore();
    x.fillStyle = '#fff'; x.font = `800 40px ${FONT}`; if ('letterSpacing' in x) x.letterSpacing = '6px';
    x.textBaseline = 'middle'; x.fillText('KARTECH', 154, 94);
    if ('letterSpacing' in x) x.letterSpacing = '0px';
    x.fillStyle = '#CFE0D4'; x.font = `500 30px ${FONT}`; x.textAlign = 'right'; x.fillText('Your order room', W - 80, 94); x.textAlign = 'left';

    // the white card
    x.save(); x.shadowColor = 'rgba(20,30,20,.10)'; x.shadowBlur = 40; x.shadowOffsetY = 12;
    round(x, 70, 180, W - 140, 1090, 44); x.fillStyle = '#fff'; x.fill(); x.restore();

    x.textBaseline = 'alphabetic';
    x.fillStyle = muted; x.font = `600 30px ${FONT}`; if ('letterSpacing' in x) x.letterSpacing = '3px';
    x.fillText('ORDER ' + String(info.ref || '').toUpperCase(), 130, 270); if ('letterSpacing' in x) x.letterSpacing = '0px';
    x.fillStyle = ink; x.font = `800 62px ${FONT}`; x.fillText(fit(x, info.item, W - 260), 130, 350);
    if (first(info.customer)){ x.fillStyle = muted; x.font = `500 34px ${FONT}`; x.fillText(fit(x, 'For ' + first(info.customer), W - 260), 130, 405); }

    // the code
    const n = q.getModuleCount(), box = 560, cell = Math.floor(box / (n + 8)), size = cell * (n + 8);
    const qx = Math.round((W - size) / 2), qy = 450;
    x.fillStyle = '#fff'; x.fillRect(qx, qy, size, size);
    x.fillStyle = ink;
    for (let r = 0; r < n; r++) for (let k = 0; k < n; k++) if (q.isDark(r, k)) x.fillRect(qx + (k + 4) * cell, qy + (r + 4) * cell, cell, cell);

    x.textAlign = 'center';
    x.fillStyle = forest; x.font = `800 44px ${FONT}`; x.fillText('Scan with your phone camera', W / 2, qy + size + 80);
    x.fillStyle = muted; x.font = `500 30px ${FONT}`; x.fillText('Send photos · Write to us · Approve your design', W / 2, qy + size + 130);
    x.font = `500 22px ${FONT}`; x.fillText(fit(x, info.link, W - 260), W / 2, qy + size + 178);
    x.textAlign = 'left';

    return await new Promise(ok => c.toBlob(ok, 'image/png'));
  }

  async function share(info){
    const blob = await card(info);
    const name = `Kartech-${String(info.ref || 'order').replace(/[^\w-]/g, '')}.png`;
    let file = null; try { file = new File([blob], name, { type: 'image/png' }); } catch (e) {}
    if (file && navigator.canShare && navigator.canShare({ files: [file] })){
      try { await navigator.share({ files: [file], title: 'Kartech order ' + info.ref }); return 'shared'; }
      catch (e){ if (e && e.name === 'AbortError') return 'cancel'; }
    }
    const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = name;
    document.body.appendChild(a); a.click(); setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 3000);
    return 'saved';
  }

  return { load, make, card, share, wa, phone };
})();
