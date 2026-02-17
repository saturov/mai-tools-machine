# drive-uploader

Upload a local file to a specific Google Drive folder via Drive API v3.

## Quick start (OAuth, personal Drive)

1) Create OAuth client credentials (Desktop app) and enable Google Drive API in Google Cloud Console.
2) Put the downloaded JSON as `tools/drive-uploader/client_secret.json` (or pass `--credentials-path`).
   This tool also auto-detects `client_secret.json` at the repository root.
3) Upload a file:

```bash
./run.sh --file-path ./some.pdf --folder-id "YOUR_FOLDER_ID"
```

The first run will open a browser for authorization and store a refreshable token at:

`~/.config/my-tools-sandbox/drive-uploader/token.json`

## Auth modes

### `--auth-mode oauth` (default)
- Uses OAuth user consent.
- Minimal scope: `drive.file`.

If you can't or don't want auto-open browser, use:

```bash
./run.sh --no-browser --file-path ./some.pdf --folder-id "YOUR_FOLDER_ID"
```

### `--auth-mode adc`
Uses Application Default Credentials, e.g.:

```bash
gcloud auth application-default login
./run.sh --auth-mode adc --file-path ./some.pdf --folder-id "YOUR_FOLDER_ID"
```

### `--auth-mode service_account`
Set `GOOGLE_APPLICATION_CREDENTIALS` to your service account key JSON, or pass it via `--credentials-path`.
Make sure the target folder is shared with the service account email.

## Output

On success, prints a single-line JSON object to stdout (safe for scripting) including `file_id` and `web_view_link` (when available).
