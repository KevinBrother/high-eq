ARG PG_IMAGE=postgres:17.6-alpine
FROM ${PG_IMAGE}
RUN apk add --no-cache curl jq redis python3
COPY --chmod=0555 infra/t34/cost.sql infra/t34/ops.sh infra/t34/gate.sh infra/t34/ticket.py infra/t34/sweeper.py /ops/
RUN mkdir -p /vault && chown postgres:postgres /vault && chmod 0700 /vault
USER postgres
ENTRYPOINT ["/bin/sh", "/ops/ops.sh"]
