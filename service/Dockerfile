# Runs the XL1 service on arm64 (Raspberry Pi) as well as amd64 -- the base
# image is multi-arch and every dependency here is pure JavaScript.
#
# For the block-height role this container needs NO wallet: /block-height uses
# a read-only gateway, and the signing routes resolve their account lazily, so
# leaving XL1_MNEMONIC unset simply means those routes error if ever called.
FROM node:24-bookworm-slim

WORKDIR /app

RUN corepack enable

# Dependencies first so edits to src/ don't invalidate the install layer.
# tsx is a devDependency and is required to run, so no --prod here.
COPY package.json pnpm-lock.yaml ./
# Frozen, and the lockfile is actually copied -- it was not, so every rebuild
# resolved dependencies afresh and the lockfile in the repo had no effect on
# the image. On a node meant to run for years, with a weekly rebuild timer,
# that means the dependency tree can drift without a single commit. It is also
# how two majors of the same SDK ended up in one tree.
RUN pnpm install --frozen-lockfile

COPY tsconfig.json tsconfig.typecheck.json ./
COPY src ./src

# Operator tools, run by hand rather than by the service: creating the
# attestation key and binding it to the producer. They live in the image
# because that is where node_modules is -- the host checkout has none, the
# service being containerised -- so `docker run <image> tsx <tool>` is the only
# place they can resolve their imports without installing a second copy of the
# dependency tree on the Pi.
COPY new-attestor.ts delegate-attestor.ts ./

# tsx strips types without checking them, so a type or scope error surfaces
# only when the offending line runs -- which for a route handler means a 500 in
# production rather than a failed build. That is exactly how a read-only
# gateway ended up cast to a runner. Checked here because this is the one step
# that always precedes a deploy.
RUN pnpm run typecheck

ENV XL1_SERVICE_PORT=8090
EXPOSE 8090

USER node

HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.XL1_SERVICE_PORT||8090)+'/block-height').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["npx", "tsx", "src/server.ts"]
