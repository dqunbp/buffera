import { mkdir, copyFile } from 'node:fs/promises';
const files = ['index.html', 'styles.css', 'app.js', 'favicon.svg'];
await mkdir(new URL('./dist/', import.meta.url), { recursive: true });
await Promise.all(files.map(file => copyFile(new URL(`./src/${file}`, import.meta.url), new URL(`./dist/${file}`, import.meta.url))));
console.log('Built Buffera landing → dist/');
