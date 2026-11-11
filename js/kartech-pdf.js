/* =====================================================================
   KARTECH: official PDF invoices and receipts, made on the phone
   KPDF.invoice(data) / KPDF.receipt(data) → a PDF file (Blob)
   KPDF.send(blob, fileName, message, phone) → phone: Share (WhatsApp gets
   the PDF itself) · computer: downloads it and opens WhatsApp
   ===================================================================== */
window.KPDF = (() => {
  let lib = null;
  const load = () => lib || (lib = new Promise((ok, no) => {
    if (window.jspdf) return ok(window.jspdf);
    const sc = document.createElement('script');
    sc.src = 'https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.2/jspdf.umd.min.js';
    sc.onload = () => ok(window.jspdf);
    sc.onerror = () => { lib = null; no(new Error('Could not load the PDF maker. Check the internet.')); };
    document.head.appendChild(sc);
  }));

  const C = { forest:[24,88,68], ink:[16,47,39], gold:[176,138,79], muted:[95,111,100], line:[227,217,198], soft:[246,241,230], green:[46,125,79], white:[255,255,255] };
  const money = n => 'KSh ' + Number(n || 0).toLocaleString('en-KE', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const num = n => Number(n || 0).toLocaleString('en-KE', { minimumFractionDigits: 0, maximumFractionDigits: 2 });
  const day = d => new Date(d).toLocaleDateString('en-GB', { day:'numeric', month:'short', year:'numeric' });
  const dayTime = d => day(d) + ' · ' + new Date(d).toLocaleTimeString('en-GB', { hour:'2-digit', minute:'2-digit' });
  const phoneNice = p => String(p || '').replace(/^\+?254/, '0').replace(/^(\d{4})(\d{3})(\d{3})$/, '$1 $2 $3');
  const checkUrl = code => new URL('check.html?k=' + code, location.href).href;

  function logo(doc, x, y, s){
    doc.setFillColor(...C.forest); doc.roundedRect(x, y, s, s, s * 0.22, s * 0.22, 'F');
    const k = s / 40 * 0.8, ox = x + s * 0.1, oy = y + s * 0.1;
    const pts = [[6,4],[14,4],[14,17],[26,4],[36,4],[22,19],[37,36],[26,36],[14,22],[14,36],[6,36]];
    const d = pts.slice(1).map((p, i) => [(p[0] - pts[i][0]) * k, (p[1] - pts[i][1]) * k]);
    doc.setFillColor(...C.gold); doc.lines(d, ox + pts[0][0] * k, oy + pts[0][1] * k, [1, 1], 'F', true);
  }
  async function qr(doc, text, x, y, size){
    if (!window.KQR) return;
    const q = await KQR.make(text), n = q.getModuleCount(), cell = size / (n + 2);
    doc.setFillColor(...C.white); doc.rect(x, y, size, size, 'F');
    doc.setFillColor(...C.ink);
    for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (q.isDark(r, c)) doc.rect(x + (c + 1) * cell, y + (r + 1) * cell, cell + 0.02, cell + 0.02, 'F');
  }
  function head(doc, biz, title, no, when){
    const W = 148;
    logo(doc, 12, 11, 13);
    doc.setTextColor(...C.ink); doc.setFont('helvetica', 'bold'); doc.setFontSize(15); doc.text('KARTECH', 28.5, 16.5, { charSpace: 0.9 });
    doc.setFont('helvetica', 'normal'); doc.setFontSize(7.5); doc.setTextColor(...C.muted);
    const lines = ['ENGINEERING · since 2001', biz.address || 'Outer Ring Road, Umoja (Mtindwa), Nairobi'];
    if (biz.phone) lines.push('Tel ' + phoneNice(biz.phone));
    if (biz.kra) lines.push('KRA PIN ' + biz.kra);
    lines.forEach((l, i) => doc.text(l, 28.5, 20.8 + i * 3.6));
    doc.setFont('helvetica', 'bold'); doc.setFontSize(15); doc.setTextColor(...C.forest); doc.text(title, W - 12, 16.5, { align: 'right', charSpace: 0.6 });
    doc.setFontSize(10); doc.setTextColor(...C.ink); doc.text(no, W - 12, 22.5, { align: 'right' });
    doc.setFont('helvetica', 'normal'); doc.setFontSize(8); doc.setTextColor(...C.muted); doc.text(when, W - 12, 27, { align: 'right' });
    const y = 21 + lines.length * 3.6 + 2;
    doc.setDrawColor(...C.gold); doc.setLineWidth(0.7); doc.line(12, Math.max(y, 31), W - 12, Math.max(y, 31));
    return Math.max(y, 31) + 8;
  }
  function label(doc, t, x, y){ doc.setFont('helvetica', 'bold'); doc.setFontSize(6.8); doc.setTextColor(...C.gold); doc.text(t, x, y, { charSpace: 0.7 }); }
  function parties(doc, y, leftLabel, inv){
    label(doc, leftLabel, 12, y); label(doc, 'FOR ORDER', 78, y);
    doc.setTextColor(...C.ink); doc.setFontSize(10); doc.setFont('helvetica', 'bold');
    const name = String(inv.customer || '').replace(/(\+?254|0)[17]\d{2}\s?\d{3}\s?\d{3}/, '').trim();
    doc.text(doc.splitTextToSize(name, 60)[0], 12, y + 5.5);
    doc.setFont('helvetica', 'normal'); doc.setFontSize(9);
    if (inv.phone) doc.text(phoneNice(inv.phone), 12, y + 10);
    doc.setFont('helvetica', 'bold'); doc.text(inv.order_ref || '—', 78, y + 5.5);
    doc.setFont('helvetica', 'normal'); doc.text('Invoice ' + inv.no, 78 + doc.getTextWidth((inv.order_ref || '—') + '  ') + 1, y + 5.5);
    if (inv.due_date) doc.text('Due: ' + day(inv.due_date), 78, y + 10);
    return y + 18;
  }
  function table(doc, y, items){
    const W = 148;
    doc.setFont('helvetica', 'bold'); doc.setFontSize(6.8); doc.setTextColor(...C.muted);
    doc.text('ITEM', 12, y, { charSpace: 0.6 }); doc.text('QTY', 92, y, { align: 'right', charSpace: 0.6 });
    doc.text('PRICE', 114, y, { align: 'right', charSpace: 0.6 }); doc.text('AMOUNT', W - 12, y, { align: 'right', charSpace: 0.6 });
    doc.setDrawColor(...C.line); doc.setLineWidth(0.3); doc.line(12, y + 2.2, W - 12, y + 2.2);
    y += 7.5; doc.setFont('helvetica', 'normal'); doc.setFontSize(9); doc.setTextColor(...C.ink);
    for (const it of items){
      const desc = doc.splitTextToSize(String(it.desc), 66);
      doc.text(desc, 12, y); doc.text(num(it.qty), 92, y, { align: 'right' }); doc.text(num(it.price), 114, y, { align: 'right' });
      doc.text(num(Number(it.qty) * Number(it.price)), W - 12, y, { align: 'right' });
      y += desc.length * 4 + 2.5; doc.setDrawColor(240, 234, 223); doc.line(12, y - 2.5, W - 12, y - 2.5); y += 2;
    }
    return y;
  }
  function sums(doc, y, rows){
    const W = 148, x = 70;
    rows.forEach(([k, v, strong], i) => {
      if (strong){ doc.setDrawColor(...C.ink); doc.setLineWidth(0.5); doc.line(x, y - 4, W - 12, y - 4); y += 1.5; }
      doc.setFont('helvetica', strong ? 'bold' : 'normal'); doc.setFontSize(strong ? 11 : 9); doc.setTextColor(...C.ink);
      doc.text(k, x, y); doc.text(v, W - 12, y, { align: 'right' }); y += strong ? 8 : 6;
    });
    return y;
  }
  async function foot(doc, lines, code){
    const W = 148, y = 184;
    doc.setDrawColor(...C.line); doc.setLineWidth(0.3); doc.line(12, y, W - 12, y);
    doc.setFont('helvetica', 'normal'); doc.setFontSize(7); doc.setTextColor(...C.muted);
    lines.forEach((l, i) => doc.text(l, 12, y + 5 + i * 3.6));
    if (code){ await qr(doc, checkUrl(code), W - 12 - 16, y + 2.5, 16); doc.text(['Scan to check', 'it is genuine'], W - 12 - 18, y + 8.5, { align: 'right' }); }
  }
  function stamp(doc, x, y, big, small){
    doc.saveGraphicsState && doc.saveGraphicsState();
    doc.setTextColor(...C.green); doc.setFont('helvetica', 'bold');
    doc.setFontSize(20); doc.text(big, x, y, { angle: 12, charSpace: 1.2 });
    doc.setFontSize(6.5); doc.text(small, x + 0.6, y + 4.4, { angle: 12, charSpace: 0.5 });
    doc.restoreGraphicsState && doc.restoreGraphicsState();
  }

  async function invoice({ biz, inv, paid }){
    const { jsPDF } = await load(); const doc = new jsPDF({ unit: 'mm', format: 'a5' });
    doc.setProperties({ title: 'Kartech invoice ' + inv.no, author: 'Kartech Engineering' });
    let y = head(doc, biz, 'INVOICE', inv.no, day(inv.created_at));
    y = parties(doc, y, 'BILL TO', inv);
    y = table(doc, y + 2, inv.items);
    const bal = Number(inv.total) - Number(paid || 0);
    y = sums(doc, y + 4, paid ? [['Total', money(inv.total)], ['Paid so far', money(paid)], ['Balance due', money(bal), true]] : [['Total', money(inv.total), true]]);
    // how to pay
    y += 2; doc.setFillColor(...C.soft); doc.roundedRect(12, y, 124, 24, 3, 3, 'F');
    label(doc, 'HOW TO PAY', 17, y + 6);
    doc.setFont('helvetica', 'normal'); doc.setFontSize(8.5); doc.setTextColor(...C.ink);
    doc.text('M-Pesa · Send money to', 17, y + 11.5);
    doc.setFont('helvetica', 'bold'); doc.setFontSize(12); doc.text(biz.pay_phone ? phoneNice(biz.pay_phone) : 'Ask Kartech', 17, y + 17.5);
    doc.setFont('helvetica', 'normal'); doc.setFontSize(8.5); if (biz.pay_name) doc.text(biz.pay_name, 17, y + 21.5);
    doc.setFontSize(7.8); doc.setTextColor(...C.muted);
    doc.text(doc.splitTextToSize('Work starts as soon as we receive your deposit. After paying, open your Kartech order page and tap "I\'ve paid", or send us the M-Pesa message.', 52), 80, y + 10);
    await foot(doc, ['Kartech Engineering · thank you for your order.', 'The balance is due before delivery.', 'Prices in Kenya Shillings.'], inv.check_code);
    return doc.output('blob');
  }

  async function receipt({ biz, inv, pay, paidSoFar, balance }){
    const { jsPDF } = await load(); const doc = new jsPDF({ unit: 'mm', format: 'a5' });
    doc.setProperties({ title: 'Kartech receipt ' + pay.no, author: 'Kartech Engineering' });
    let y = head(doc, biz, 'RECEIPT', pay.no, dayTime(pay.created_at));
    y = parties(doc, y, 'RECEIVED FROM', inv);
    y = table(doc, y + 2, inv.items);
    // the payment
    y += 1; doc.setFillColor(...C.forest); doc.roundedRect(12, y, 124, 20, 3, 3, 'F');
    doc.setTextColor(...C.white); doc.setFont('helvetica', 'normal'); doc.setFontSize(7); doc.text('AMOUNT PAID', 17, y + 7, { charSpace: 0.6 });
    doc.setFont('helvetica', 'bold'); doc.setFontSize(17); doc.text(money(pay.amount), 17, y + 15);
    const kind = balance <= 0 ? (paidSoFar > pay.amount ? 'Final payment' : 'Paid in full') : (paidSoFar <= pay.amount ? 'Deposit' : 'Part payment');
    doc.setFont('helvetica', 'normal'); doc.setFontSize(8);
    doc.text(pay.method + (pay.reference ? ' code' : ''), 131, y + 6.5, { align: 'right' });
    if (pay.reference){ doc.setFont('helvetica', 'bold'); doc.setFontSize(10.5); doc.text(pay.reference, 131, y + 11.8, { align: 'right', charSpace: 0.3 }); }
    doc.setFont('helvetica', 'normal'); doc.setFontSize(8); doc.text(kind, 131, y + 16.5, { align: 'right' });
    y += 28;
    const yS = y;
    y = sums(doc, y, [['Invoice total', money(inv.total)], ['Paid so far', money(paidSoFar)], ['Balance due', money(Math.max(0, balance)), true]]);
    stamp(doc, 18, yS + 9, balance <= 0 ? 'PAID IN FULL' : 'PAID', (kind.toUpperCase() + ' · ' + day(pay.created_at).toUpperCase()));
    await foot(doc, ['Received and confirmed by Kartech Engineering.', 'Thank you for your business. Please keep this receipt.', balance > 0 ? 'The balance is due before delivery.' : 'Fully paid. Thank you!'], pay.check_code);
    return doc.output('blob');
  }

  // phone: Share sheet (the PDF goes into WhatsApp) · computer: download + open WhatsApp
  async function send(blob, fileName, message, phone){
    let file = null; try { file = new File([blob], fileName, { type: 'application/pdf' }); } catch (e) {}
    if (file && navigator.canShare && navigator.canShare({ files: [file] })){
      try { await navigator.share({ files: [file], text: message }); return 'shared'; }
      catch (e){ if (e && e.name === 'AbortError') return 'cancel'; }
    }
    const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = fileName;
    document.body.appendChild(a); a.click(); setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 4000);
    const ph = String(phone || '').replace(/\D/g, '').replace(/^0/, '254');
    if (/^254\d{9}$/.test(ph)) window.open('https://wa.me/' + ph + '?text=' + encodeURIComponent(message + '\n(PDF attached)'), '_blank', 'noopener');
    return 'saved';
  }

  return { load, invoice, receipt, send, money };
})();
