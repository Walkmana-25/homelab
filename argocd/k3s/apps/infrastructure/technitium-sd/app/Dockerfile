FROM python:3.12-slim

RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app

COPY main.py .

USER 10001

EXPOSE 8080

CMD ["python3", "-u", "main.py"]
