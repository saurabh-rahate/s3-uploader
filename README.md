# s3-uploader

Uploads JSON files to Amazon S3. Each file sits next to a `config.json` that says where it goes, and `make` runs the checks, the diff and the upload.

## Layout

```
src/files/<dir>/<environment>/
├── config.json    # where the file goes
└── upload.json    # the file to upload, named in config.json
```

For example, `src/files/MY_FOLDER/dev/`. Other environments go next to it, as `src/files/MY_FOLDER/uat/` and `src/files/MY_FOLDER/prod/`. Each folder holds exactly one file to upload.

## config.json

```json
{
  "region": "ap-south-1",
  "bucket": "sample-bucket",
  "path": "uploaded-file/jsons",
  "file": "upload.json"
}
```

| Field | Required | Description |
|---|---|---|
| `bucket` | Yes | S3 bucket to upload to. |
| `path` | Yes | Folder inside the bucket. Slashes at the start or end are ignored. |
| `file` | Yes | Name of the file to upload. It must sit next to `config.json` and contain valid JSON. |
| `region` | No | AWS region of the bucket. Defaults to `ap-south-1`. |

This example uploads `upload.json` to `s3://sample-bucket/uploaded-file/jsons/upload.json`.

The region only comes from `config.json` or the default. The `AWS_REGION` and `AWS_DEFAULT_REGION` environment variables don't change it.

## Commands

```sh
make lint                                    # check every config.json and JSON file under src/files
make diff   environment=dev dir=MY_FOLDER    # show what an upload would change in S3
make upload environment=dev dir=MY_FOLDER    # upload the file, replacing what's there
```

`environment` and `dir` must be single folder names.

**`make lint`** checks every `config.json` the same way `diff` and `upload` do, and checks that every JSON file under `src/files` is valid. It lists every problem it finds, then fails if there were any. It doesn't contact AWS.

**`make diff`** downloads the file currently in S3 and prints a diff against the local file, with removed lines marked `-` and added lines marked `+`. If nothing is in S3 yet, every line shows as added. It compares the files exactly as written, so indentation changes show up too. It fails only on errors, not when there are changes.

**`make upload`** uploads the file with content type `application/json`, replacing any file already at the destination.

`diff` and `upload` check the config and the file before contacting AWS, so config mistakes show up even without credentials.

## Requirements

- `make`, `bash`, `jq` and `diff`
- AWS CLI v2, for `diff` and `upload`

On macOS, run `brew install awscli`, plus `brew install jq` if `jq` isn't already installed.

## Credentials

`diff` and `upload` read credentials from these environment variables:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SESSION_TOKEN`, only if the credentials are temporary

| Command | Permissions needed |
|---|---|
| `diff` | `s3:GetObject` on the destination, e.g. `arn:aws:s3:::sample-bucket/uploaded-file/jsons/*`, and `s3:ListBucket` on the bucket, e.g. `arn:aws:s3:::sample-bucket` |
| `upload` | `s3:PutObject` on the destination |

Without `s3:ListBucket`, S3 reports a missing file as access denied, so `diff` fails instead of showing the new file. If the bucket is encrypted with a KMS key, the credentials also need access to that key.

Give each environment its own credentials that can only reach that environment's bucket or path. Then a config copied from another environment and not updated fails, instead of overwriting the wrong file.

## GoCD pipeline

| Stage | Command | Credentials |
|---|---|---|
| lint | `make lint` | None |
| diff | `make diff environment=<environment> dir=<dir>` | Read-only |
| upload (manual trigger) | `make upload environment=<environment> dir=<dir>` | Write |

Set the credentials as secure environment variables on the diff and upload stages. Agents need the tools listed under [Requirements](#requirements).

## Adding an upload

1. Create `src/files/<dir>/<environment>/` and put the JSON file in it.
2. Add a `config.json` next to it.
3. Run `make lint`, then `make diff environment=<environment> dir=<dir>`.

## Known limitation

`make lint` uses jq, which accepts `Infinity` and `-Infinity` as numbers even though they aren't valid JSON.
