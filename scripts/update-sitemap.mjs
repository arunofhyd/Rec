import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const projectRoot = path.resolve(__dirname, '..');

const candidatePaths = [
  path.resolve(projectRoot, 'public/sitemap.xml'),
  path.resolve(projectRoot, 'sitemap.xml'),
  path.resolve(projectRoot, 'static/sitemap.xml'),
  path.resolve(projectRoot, 'dist/sitemap.xml')
];

const targetPath = candidatePaths.find(p => fs.existsSync(p));

try {
  const today = new Date().toISOString().split('T')[0];
  if (targetPath) {
    let content = fs.readFileSync(targetPath, 'utf8');

    if (/<lastmod[\s\S]*?(?:<\/lastmod>|\/>)/gi.test(content)) {
      content = content.replace(/<lastmod[\s\S]*?(?:<\/lastmod>|\/>)/gi, `<lastmod>${today}</lastmod>`);
    } else {
      content = content.replace(/<\/url>/gi, `  <lastmod>${today}</lastmod>\n  </url>`);
    }

    fs.writeFileSync(targetPath, content, 'utf8');
    const relativePath = path.relative(projectRoot, targetPath);
    console.log(`[sitemap] Updated lastmod date to ${today} in ${relativePath}`);
  } else {
    console.warn('[sitemap] sitemap.xml not found in common project locations.');
  }
} catch (err) {
  console.error('[sitemap] Failed to update sitemap lastmod:', err);
}
