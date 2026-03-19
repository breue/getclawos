# Website Deployment (get.marginmachines.com)

This directory is a static site bundle you can deploy to GitHub Pages, Cloudflare Pages, Netlify, or S3/CloudFront.

Required files for one-line install:

- `install.sh`
- `releases/stable/latest.env`
- `releases/stable/latest.json`

Prepare those files after building release assets:

```bash
./scripts/package v1.0.0
./scripts/build_macos_app
./scripts/package_macos_dmg v1.0.0
./scripts/prepare_web_release v1.0.0 "https://github.com/<org>/<repo>/releases/download/v1.0.0"
```

Then deploy the entire `website/` directory to your hosting provider and ensure:

- `https://get.marginmachines.com/install.sh` resolves to `website/install.sh`
- `https://get.marginmachines.com/releases/stable/latest.env` resolves to `website/releases/stable/latest.env`
