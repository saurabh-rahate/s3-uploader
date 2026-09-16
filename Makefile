# Lint, diff and upload JSON files to S3. Run `make` to see usage.
#
# Each upload lives in src/files/<dir>/<environment>/, with a config.json saying
# where the file goes. The work is done by scripts/s3-uploader.sh.

SCRIPT := scripts/s3-uploader.sh

.DEFAULT_GOAL := help
.PHONY: help lint diff upload

help:
	@echo "Usage:"
	@echo "  make lint                                 Check every config.json and JSON file under src/files"
	@echo "  make diff   environment=<env> dir=<dir>   Show what an upload would change in S3"
	@echo "  make upload environment=<env> dir=<dir>   Upload the file to S3"
	@echo ""
	@echo "Example:"
	@echo "  make diff environment=dev dir=MY_FOLDER"

lint:
	@bash $(SCRIPT) lint

diff:
	@bash $(SCRIPT) diff '$(environment)' '$(dir)'

upload:
	@bash $(SCRIPT) upload '$(environment)' '$(dir)'
