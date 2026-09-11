FROM python:3.12-slim

WORKDIR /srv

# Dependencies are copied and installed on their own so a source change
# does not invalidate the install layer.
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/

RUN useradd --create-home appuser
USER appuser

EXPOSE 8080

# gunicorn, not app.py directly. Running the module as __main__ is what
# switched on the Werkzeug debugger; this never reaches that code path.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "app.app:app"]
