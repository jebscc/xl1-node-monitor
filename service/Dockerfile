# Runs the XL1 service on arm64 (Raspberry Pi) as well as amd64 -- the base
# image is multi-arch and every dependency here is pure JavaScript.
#
# For the block-height role this container needs NO wallet: /block-height uses
# a read-only gateway, and the signing routes resolve their account lazily, so
# leaving XL1_MNEMONIC unset simply means those routes error if ever called.
#
# NODE 26 IS NOT LTS UNTIL 2026-10-28, and sitting here anyway is a deliberate
# call rather than an oversight. Node 24 is the Active LTS until 2026-10-20 and
# 26 becomes LTS eight days after that; moving on 2026-09-19 puts this image on
# the line it will sit on for the next two years rather than moving it twice.
# If you are installing this today and would rather stay on Active LTS,
# node:24-bookworm-slim is a one-word change and everything here works on it.
#
# It does NOT unblock @xyo-network/sdk 8, which declares engines node ^26.
# That is one of two locks; the other is that xl1-sdk 5.5.4 still declares
# @xyo-network/sdk ^7.4 as a PEER, so taking sdk 8 would break the XL1 SDK's
# own requirement whatever Node this image runs. Both have to clear before
# the pin in package.json can move.
FROM node:26-bookworm-slim

WORKDIR /app

# COREPACK IS NOT IN THE NODE 26 IMAGE. It shipped inside node:24 and this
# line was a bare `corepack enable` until 2026-09-19, when the first build on
# 26 failed at once: `/bin/sh: 1: corepack: not found`, exit 127. Measured in
# the image rather than inferred -- node:26-bookworm-slim is v26.9.0 with npm
# 11.19.1 and NEITHER corepack nor pnpm on the path. The Node changelog still
# lists corepack being updated, which is what misled the change: the package
# is still maintained, it is simply no longer bundled in the distribution.
#
# Installed rather than swapped for `npm i -g pnpm`, because `packageManager`
# in package.json pins pnpm@9.15.0 WITH A sha512 INTEGRITY HASH and corepack
# is what verifies it. Installing pnpm directly would run whatever the
# registry served and check nothing.
RUN npm install -g corepack@latest && corepack enable

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
# attestation key, binding it to the producer, and proving the anchoring path
# end to end. They live in the image because that is where node_modules is --
# the host checkout has none, the service being containerised -- so
# `docker exec <container> npx tsx <tool>` is the only place they can resolve
# their imports without installing a second copy of the dependency tree on the
# Pi. Measured on 2026-09-18: running verify-headless.ts meant copying it in
# with `docker cp` first, and its own import of src/anchorRecord.ts failed
# against an image built before that file existed.
#
# verify-headless.ts SPENDS GAS when run. Being in the image costs nothing --
# nothing runs it on start, and the service never calls it.
COPY new-attestor.ts delegate-attestor.ts verify-headless.ts ./

# tsx strips types without checking them, so a type or scope error surfaces
# only when the offending line runs -- which for a route handler means a 500 in
# production rather than a failed build. That is exactly how a read-only
# gateway ended up cast to a runner. Checked here because this is the one step
# that always precedes a deploy.
RUN pnpm run typecheck

# AND THE HALF A TYPECHECK CANNOT SEE. Types come from whatever version is on
# disk, so tsc describes the tree it was given rather than the tree the
# packages asked for -- and `pnpm install --frozen-lockfile` above installs an
# unmet peer in silence, where a resolving install would have warned. Measured
# on PR #33: @xyo-network/sdk 8.0.0 above sdk-protocol 7.3.2, green install,
# green typecheck, and the packages that do the anchoring refusing the SDK
# underneath them.
#
# Here because this is the one step that always precedes a deploy. A tree the
# stack disagrees with cannot become an image, so it cannot reach the Pi.
# Only disagreements INSIDE the stack fail the build: @noble/post-quantum has
# shipped a minor ahead of what three XYO packages ask for since before this
# existed, and stopping every deploy over another repository's decision is not
# a gate, it is an outage with a reason attached.
COPY scripts/peer-audit.mjs ./scripts/
RUN node scripts/peer-audit.mjs .

ENV XL1_SERVICE_PORT=8090
EXPOSE 8090

USER node

HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.XL1_SERVICE_PORT||8090)+'/block-height').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["npx", "tsx", "src/server.ts"]
