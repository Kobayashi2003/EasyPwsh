# Launch every self-hosted app behind the single public port (:30709).
#
# The gateway supervises the apps itself and fans out by path prefix, so this is
# one command in one pane — not one pane per project. It also has to be: each
# project now fronts itself with Caddy on :30709 and they would fight over the
# port if started side by side.
#
#   http://localhost:30709/   landing page — pick an app
#
# See D:\Program\Code\AppGateway\README.md for running a subset or a single app
# standalone.

run-cmds-in-wt "& 'D:\Program\Code\AppGateway\gateway.ps1'" -NoProfile
