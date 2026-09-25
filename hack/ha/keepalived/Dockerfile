# Keepalived for the Infra LB (backlog D11/D14): own minimal image, not a third-party one.
# Base and package are pinned (backlog "Закреплённые версии"): Alpine 3.24 by digest, keepalived from its repository by exact version.
FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
RUN apk add --no-cache keepalived=2.3.4-r2
ENTRYPOINT ["keepalived"]
