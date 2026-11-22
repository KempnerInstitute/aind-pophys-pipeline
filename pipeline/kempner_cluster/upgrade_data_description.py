"""Upgrade an aind-data-schema v1 data_description.json to v2 for the metadata aggregator."""

import json
import sys
import types


def stub_document_db():
    """The upgrader imports a DocDB client that it calls only for derived data."""

    class MetadataDbClient:
        def __init__(self, *args, **kwargs):
            pass

        def retrieve_docdb_records(self, *args, **kwargs):
            raise RuntimeError("DocDB is not reachable from this cluster")

    package = types.ModuleType("aind_data_access_api")
    module = types.ModuleType("aind_data_access_api.document_db")
    module.MetadataDbClient = MetadataDbClient
    package.document_db = module
    sys.modules["aind_data_access_api"] = package
    sys.modules["aind_data_access_api.document_db"] = module


def main():
    upgrader_src, source, target = sys.argv[1:4]
    stub_document_db()
    sys.path.insert(0, upgrader_src)
    from aind_data_schema.core.data_description import DataDescription
    from aind_metadata_upgrader.data_description.v1v2 import DataDescriptionV1V2

    with open(source) as handle:
        v1 = json.load(handle)
    schema_version = DataDescription.model_fields["schema_version"].default
    upgraded = DataDescriptionV1V2().upgrade(v1, schema_version)
    description = DataDescription(**upgraded)
    with open(target, "w") as handle:
        handle.write(description.model_dump_json(indent=3))
    print(f"upgraded {v1.get('schema_version')} -> {description.schema_version}: {description.name}")


if __name__ == "__main__":
    main()
