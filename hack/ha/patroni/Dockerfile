# PostgreSQL + Patroni image (backlog H2.2). No maintained upstream image exists
# (Spilo's last release is 2023), so Patroni is layered on the pinned PostgreSQL image.
FROM postgres:15.19-alpine3.24@sha256:f7d23353e1b15400d22ebe31189f4d314b87a4c129cc400c8c2d8d4ca127bf81

RUN apk add --no-cache python3 curl \
 && python3 -m venv /opt/patroni
COPY constraints.txt /tmp/constraints.txt
RUN /opt/patroni/bin/pip install --no-cache-dir -c /tmp/constraints.txt 'patroni[consul,psycopg3]==4.1.5' \
 && rm /tmp/constraints.txt

ENV PATH=/opt/patroni/bin:$PATH
USER postgres
ENTRYPOINT ["patroni"]
CMD ["/etc/patroni/patroni.yml"]
