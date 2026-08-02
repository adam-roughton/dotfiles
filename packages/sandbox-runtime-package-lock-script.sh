npm pack @anthropic-ai/sandbox-runtime@0.0.65 # replace with target version
tar xf anthropic-sandbox-runtime-0.0.65.tgz
cd package && npm install --package-lock-only
cp package-lock.json ../../packages/sandbox-runtime-package-lock.json
