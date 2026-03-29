#!/bin/bash
# Initialize a new Encore project

set -e

LANGUAGE=${1:-go}
APP_NAME=${2:-my-encore-app}

if ! command -v encore &> /dev/null; then
    echo "Encore CLI not found. Installing..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        brew install encoredev/tap/encore
    else
        curl -L https://encore.dev/install.sh | bash
    fi
fi

echo "Creating new Encore app: $APP_NAME ($LANGUAGE)"
encore app create "$APP_NAME" --$LANGUAGE

cd "$APP_NAME"

echo ""
echo "✅ Encore app created successfully!"
echo ""
echo "Next steps:"
echo "  cd $APP_NAME"
echo "  encore run          # Start development server"
echo "  encore test         # Run tests"
echo "  open http://localhost:9400  # Open local dashboard"
