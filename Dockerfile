FROM python:latest

WORKDIR /app

COPY . .

RUN pip install -r app/requirements.txt

ENV DB_PASSWORD=REDACTED_FAKE_PASSWORD

EXPOSE 8080

CMD ["python", "app/app.py"]
