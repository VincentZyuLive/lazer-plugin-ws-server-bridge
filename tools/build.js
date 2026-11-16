const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const rootDir = path.resolve(__dirname, '..');
const distDir = path.join(rootDir, 'dist');
const manifest = JSON.parse(fs.readFileSync(path.join(rootDir, 'manifest.json'), 'utf8'));

if (!fs.existsSync(distDir)) {
  fs.mkdirSync(distDir, { recursive: true });
}

const zipName = `${manifest.id}.zip`;
const zipPath = path.join(distDir, zipName);

if (fs.existsSync(zipPath)) {
  fs.unlinkSync(zipPath);
}

const filesToInclude = ['manifest.json', 'main.lua', 'README.md', 'LICENSE'];

console.log(`Packaging ${zipName}...`);

// Use native PowerShell or archiver/tar to create zip
if (process.platform === 'win32') {
  const fileList = filesToInclude.map(f => `'${f}'`).join(',');
  execSync(`powershell -NoProfile -Command "Compress-Archive -Path ${fileList} -DestinationPath '${zipPath}' -Force"`, {
    cwd: rootDir,
    stdio: 'inherit'
  });
} else {
  execSync(`zip -r "${zipPath}" ${filesToInclude.join(' ')}`, {
    cwd: rootDir,
    stdio: 'inherit'
  });
}

console.log(`Created: ${zipPath} (${fs.statSync(zipPath).size} bytes)`);
