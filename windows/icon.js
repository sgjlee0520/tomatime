// The tray icon, drawn pixel by pixel (no image files, no canvas): a tomato in the tier's color; while the timer
// runs, the minutes left on it; a gold dot when friends are focusing. Returns raw BGRA pixels for nativeImage.
const glyphs = {  // 3 × 5 pixel digits, rows top to bottom
  0: '111101101101111', 1: '010110010010111', 2: '111001111100111', 3: '111001111001111', 4: '101101111001001',
  5: '111100111001111', 6: '111100111101111', 7: '111001010010010', 8: '111101111101111', 9: '111101111001111',
  h: '100100111101101',
};
const rgb = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));

// size: 16 or 32. text: up to two characters ("24", "7", "2h"), or '' for a plain tomato.
export function tomatoBitmap(size, color, text = '', dot = false) {
  const px = Buffer.alloc(size * size * 4), body = rgb(color), k = size / 16;
  const dark = (0.299 * body[0] + 0.587 * body[1] + 0.114 * body[2]) / 255 > 0.6;
  const ellipse = (x, y, cx, cy, rx, ry) => ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1;
  // With a number the body is a rounded square, so the digits' corners stay on color.
  const inBody = text
    ? (x, y) => y >= 3 * k && Math.hypot(Math.max(3 * k - x, x - 13 * k, 0), Math.max(6 * k - y, y - 13 * k, 0)) <= 3 * k
    : (x, y) => ellipse(x, y, 8 * k, 9.3 * k, 7.2 * k, 6.2 * k);
  const layers = [  // back to front: [test, [r, g, b], alpha]
    [inBody, body, 1],
    [(x, y) => ellipse(x, y, 8 * k, 3.2 * k, 3.4 * k, 1.9 * k), [26, 115, 38], 1],                       // leaf
    [(x, y) => !text && ellipse(x, y, 4.8 * k, 8 * k, 1.4 * k, 1.4 * k), [255, 255, 255], 0.6],           // shine
    [(x, y) => dot && ellipse(x, y, 13.4 * k, 2.6 * k, 2.6 * k, 2.6 * k), [27, 27, 27], 1],               // dot's ring
    [(x, y) => dot && ellipse(x, y, 13.4 * k, 2.6 * k, 1.9 * k, 1.9 * k), [255, 194, 26], 1],             // friends focusing
  ];
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let r = 0, g = 0, b = 0, a = 0;
      for (let s = 0; s < 16; s++) {  // 4 × 4 samples per pixel: smooth edges
        const sx = x + (s % 4 + 0.5) / 4, sy = y + (Math.floor(s / 4) + 0.5) / 4;
        let c = null, ca = 0;
        for (const [test, col, alpha] of layers) {
          if (!test(sx, sy)) continue;
          c = c ? c.map((v, i) => v * (1 - alpha) + col[i] * alpha) : col;
          ca = Math.max(ca, alpha);
        }
        if (c) { r += c[0] * ca; g += c[1] * ca; b += c[2] * ca; a += ca; }
      }
      const i = (y * size + x) * 4;
      if (a > 0) { px[i] = Math.round(b / a); px[i + 1] = Math.round(g / a); px[i + 2] = Math.round(r / a); px[i + 3] = Math.round(a / 16 * 255); }
    }
  }
  const chars = [...text].filter((ch) => glyphs[ch]), s = 2 * k, ink = dark ? [27, 27, 27] : [255, 255, 255];
  const x0 = Math.round((size - (chars.length * 4 - 1) * s) / 2), y0 = 5 * k;
  chars.forEach((ch, n) => [...glyphs[ch]].forEach((on, j) => {
    if (on !== '1') return;
    for (let dy = 0; dy < s; dy++) for (let dx = 0; dx < s; dx++) {
      const i = ((y0 + Math.floor(j / 3) * s + dy) * size + x0 + (n * 4 + j % 3) * s + dx) * 4;
      px[i] = ink[2]; px[i + 1] = ink[1]; px[i + 2] = ink[0]; px[i + 3] = 255;
    }
  }));
  return px;
}

// What goes on the icon: whole minutes left, rounded up; past 99 minutes, hours ("2h").
export const iconText = (secondsLeft) => {
  const m = Math.ceil(secondsLeft / 60);
  return m > 99 ? `${Math.min(9, Math.round(m / 60))}h` : String(m);
};
