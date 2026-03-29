#!/bin/bash
# PocketBase Migration Helper
# Creates a new migration file with proper naming

set -e

MIGRATION_NAME="${1:-migration}"
PB_DIR="${2:-.}"

# Generate timestamp
TIMESTAMP=$(date +%Y%m%d%H%M%S)
FILENAME="${TIMESTAMP}_${MIGRATION_NAME}.go"

# Create migrations directory if it doesn't exist
mkdir -p "$PB_DIR/pb_migrations"

# Create migration file
cat > "$PB_DIR/pb_migrations/$FILENAME" << 'EOF'
package migrations

import (
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/daos"
	"github.com/pocketbase/pocketbase/models"
	"github.com/pocketbase/pocketbase/models/schema"
	"github.com/pocketbase/pocketbase/tools/types"
)

func init() {
	AppMigrations.Register(func(db dbx.Builder) error {
		dao := daos.New(db)

		// Example: Create a new collection
		// collection := &models.Collection{
		//     Name: "posts",
		//     Schema: schema.NewSchema(
		//         &schema.SchemaField{
		//             Name:     "title",
		//             Type:     schema.FieldTypeText,
		//             Required: true,
		//         },
		//         &schema.SchemaField{
		//             Name: "content",
		//             Type: schema.FieldTypeText,
		//         },
		//     ),
		// }
		// return dao.SaveCollection(collection)

		return nil
	}, func(db dbx.Builder) error {
		// Optional: Add rollback logic here
		return nil
	})
}
EOF

echo "Created migration: pb_migrations/$FILENAME"
echo ""
echo "Edit the file to add your migration logic."
echo "Run with: ./pocketbase migrate up"
