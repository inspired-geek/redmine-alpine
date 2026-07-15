# frozen_string_literal: true

migration_base = if ActiveRecord::Migration.respond_to?(:current_version)
                   ActiveRecord::Migration[ActiveRecord::Migration.current_version]
                 else
                   ActiveRecord::Migration
                 end

Object.const_set(
  :CreateSmokePluginRecords,
  Class.new(migration_base) do
    def up
      create_table :smoke_plugin_records do |table|
        table.string :value, null: false
      end
    end

    def down
      drop_table :smoke_plugin_records
    end
  end
)
