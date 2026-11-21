#!/usr/bin/env bash

# `npm start` is just `node dist/index.js`; call node directly so the runtime
# image needs no npm CLI (see Dockerfile).
node /app/dist/index.js &
nginx
