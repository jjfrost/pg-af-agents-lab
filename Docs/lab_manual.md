# Lab Manual

This guide walks through the full Agentic App lab end to end on your own workstation. All steps now assume you control the Azure subscription, Azure Developer CLI (`azd`), and Azure CLI sign-in experience. Replace any placeholder values (for example `<env-name>`) with your own names.

# Table of Contents

1. [Part 0 - Provision Azure Resources with azd](#part-0---provision-azure-resources-with-azd)
    1. [Authenticate and configure azd](#authenticate-and-configure-azd)
    2. [Create or select an azd environment](#create-or-select-an-azd-environment)
    3. [Run azd up](#run-azd-up)
    4. [Capture connection details](#capture-connection-details)
2. [Part 1 - Setup your Azure PostgreSQL Database](#part-1---setup-your-azure-postgresql-database)
    1. [Connect with the VS Code PostgreSQL extension](#connect-with-the-vs-code-postgresql-extension)
    2. [Launch the integrated psql shell](#launch-the-integrated-psql-shell)
    3. [Populate the database with sample data](#populate-the-database-with-sample-data)
    4. [Use the Query Editor](#use-the-query-editor)
    5. [Install and configure the azure_ai extension](#install-and-configure-the-azure_ai-extension)
    6. [Explore the azure_ai schema](#explore-the-azure_ai-schema)
    7. [Review the azure_openai schema](#review-the-azure_openai-schema)
3. [Part 2 - Using AI-driven features in Postgres](#part-2---using-ai-driven-features-in-postgres)
    1. [Pattern matching queries](#pattern-matching-queries)
    2. [Semantic vector search and DiskANN](#semantic-vector-search-and-diskann)
        - [Create, store, and index embeddings](#create-store-and-index-embeddings)
        - [Perform a semantic search query](#perform-a-semantic-search-query)
4. [Part 3 - Build the Agentic App](#part-3---build-the-agentic-app)
    1. [Open the notebook](#open-the-notebook)

---

# Part 0 - Provision Azure Resources with azd

`azd up` provisions every Azure resource defined in `infra/main.bicep` and configures deployments using the information in `azure.yaml`. The template creates an Azure Database for PostgreSQL flexible server (with Entra ID authentication enabled) plus an Azure OpenAI resource that hosts `gpt-4o` and `text-embedding-3-small` deployments.

## Authenticate and configure azd

1. Install the Azure CLI and Azure Developer CLI (`azd >= 1.10.0`).
2. Sign in to your Azure subscription using the credentials for your own tenant (no Temporary Access Pass is needed outside Skillable):

    ```powershell
    azd auth login
    ```

    Use the same account password you use for the Azure portal.

## Create or select an azd environment

If this is your first time running the lab, create a new azd environment. Otherwise, select the existing one.

```powershell
azd env new <env-name>
```

`azd env new` stores environment metadata under `.azure/<env-name>` and becomes the default context for subsequent commands.

## Run azd up

Run `azd up` from the repository root (`c:\dev\repos\pg-af-agents-lab`). This command handles provisioning and deployment in a single step.

```powershell
azd up
```

`azd up` deploys the Bicep templates in `infra/`, creates the `cases` database, allowlists the `azure_ai`, `vector`, `age`, and `pg_diskann` extensions, and sets you (the deployer) as an Azure Database admin. The post-provision hook defined in `azure.yaml` runs `Scripts/write_env.ps1`, which resolves the live resource endpoints and writes them to `.env` at the repo root.

If you need to regenerate the `.env` file later, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Scripts\write_env.ps1
```

## Capture connection details

`azd env get-values` exposes every output from `main.bicep`. Review or export anything you need for the remainder of the lab:

```powershell
azd env get-values
```

You should see values such as `AZURE_POSTGRES_DOMAIN`, `AZURE_POSTGRES_USER`, `AZURE_OPENAI_ENDPOINT`, and `AZURE_OPENAI_KEY`. The `.env` file mirrors these settings and is consumed both by PowerShell scripts and the Jupyter notebook in Part 3.

---

# Part 1 - Setup your Azure PostgreSQL Database

The following sections walk through connecting to the `cases` database, loading the dataset, and configuring the Azure AI integrations. You will continue to use your own Azure credentials whenever prompted.

## Connect with the VS Code PostgreSQL extension

1. Open VS Code in the repo (`code .` from PowerShell works well).
2. Install the **PostgreSQL** extension from Microsoft (Elephant icon) if it is not already present.
3. In the POSTGRESQL view, select **Add Connection**.
4. Choose **Browse Azure** and sign in with the same Microsoft Entra account you used for `azd auth login`. When prompted, allow the extension to access Azure resources on your behalf.
5. Fill in the connection dialog:
    - **Subscription / Resource Group / Location / Server**: select the entries that correspond to the environment you just provisioned.
    - **Database**: `cases`.
    - **Authentication Type**: `Entra Auth`.
6. Select your signed-in Azure account when asked for the Entra ID identity, provide a friendly **Connection Name**, click **Test Connection**, then **Save & Connect**.

You are now authenticated to Azure Database for PostgreSQL using Entra ID rather than a temporary password.

## Launch the integrated psql shell

1. In the PostgreSQL explorer, expand **Databases**.
2. Right-click `cases` and choose **Connect with PSQL**. VS Code opens an integrated terminal with a ready-to-use `psql` session that uses the same Entra ID token as the extension.

## Populate the database with sample data

The `Scripts/initialize_dataset.sql` script creates the `cases` table schema and bulk-loads the CSV data.

```psql
\i ./Scripts/initialize_dataset.sql;
```

Once the script finishes, enable extended display to make tall result sets easier to read:

```psql
\x auto
```

You can now sample the data:

```sql
SELECT name FROM cases LIMIT 5;
```

## Use the Query Editor

1. In the PostgreSQL explorer, right-click the `cases` database and choose **New Query**.
2. A new SQL editor tab opens that stays connected to the server. The green status indicator in the bottom-right corner confirms the connection state and target database.

Use this editor for the remaining SQL commands.

## Install and configure the `azure_ai` extension

1. Confirm the server allowlist includes the required extensions:

    ```sql
    SHOW azure.extensions;
    ```

    The output should include `azure_ai`, `vector`, `age`, and `pg_diskann`. These values are configured during `azd up` by `infra/pg.bicep`.

2. Install the extension inside the `cases` database:

    ```sql
    CREATE EXTENSION IF NOT EXISTS azure_ai;
    ```

    Adding `IF NOT EXISTS` keeps the command idempotent.

## Explore the azure_ai schema

The `azure_ai` schema hosts helper functions and configuration tables used to interact with Azure AI services securely.

| Schema   | Name        | Result Type | Arguments                  | Kind |
|----------|-------------|-------------|----------------------------|------|
| azure_ai | get_setting | text        | key text                   | func |
| azure_ai | set_setting | void        | key text, value text       | func |
| azure_ai | version     | text        |                            | func |

- Members of the `azure_ai_settings_manager` role can read and write settings.
- Every admin user (anyone with `azure_pg_admin`) is automatically granted this role during provisioning.

### Configure Azure OpenAI settings

1. Open `.env` in the repo root and locate the following entries created by `Scripts/write_env.ps1`:
    - `AZURE_OPENAI_ENDPOINT`
    - `AZURE_OPENAI_KEY`
2. Back in the SQL editor, set the values:

    ```sql
    SELECT azure_ai.set_setting('azure_openai.endpoint', '<your-endpoint>');
    SELECT azure_ai.set_setting('azure_openai.subscription_key', '<your-key>');
    ```

3. Validate the settings:

    ```sql
    SELECT azure_ai.get_setting('azure_openai.endpoint');
    SELECT azure_ai.get_setting('azure_openai.subscription_key');
    ```

Once these values are stored, the database can call Azure OpenAI without embedding secrets in scripts or notebooks.

## Review the azure_openai schema

The `azure_openai` schema exposes helper functions for calling Azure OpenAI. The primary entry point is `create_embeddings`, available in single-text and array forms. Run a quick smoke test to confirm connectivity:

```sql
SELECT LEFT(azure_openai.create_embeddings('text-embedding-3-small', 'Sample text for PostgreSQL Lab')::text, 100) AS vector_preview;
```

Expect abbreviated vectors similar to `{0.02006,0.00022,...}`. Storing vectors in-database requires the `vector` extension, which was already allowlisted during provisioning.

---

# Part 2 - Using AI-driven features in Postgres

The remaining SQL code runs in the same VS Code Query Editor session.

## Pattern matching queries

Case-insensitive pattern matching helps illustrate why vector similarity search is valuable. Start with a basic query that attempts to find a natural-language phrase:

```sql
SELECT id, name, opinion
FROM cases
WHERE opinion ILIKE '%Water leaking into the apartment from the floor above%';
```

This exact pattern rarely appears, so the result set is commonly empty. Semantic search solves that limitation by using embeddings instead of literal text matching.

## Semantic vector search and DiskANN

The next steps generate embeddings for each case, create an approximate nearest neighbor index, and run semantic searches.

### Create, store, and index embeddings

1. Ensure the `vector` extension is installed:

    ```sql
    CREATE EXTENSION IF NOT EXISTS vector;
    ```

2. Add a vector column sized for the 1,536 dimensions produced by `text-embedding-3-small`:

    ```sql
    ALTER TABLE cases ADD COLUMN IF NOT EXISTS opinions_vector vector(1536);
    ```

3. Generate embeddings for every row. Expect a multi-minute runtime and occasional retry warnings while the command works through the dataset.

    ```sql
    UPDATE cases
    SET opinions_vector = azure_openai.create_embeddings(
        'text-embedding-3-small',
        name || LEFT(opinion, 8000),
        max_attempts => 5,
        retry_delay_ms => 500
    )::vector
    WHERE opinions_vector IS NULL;
    ```

4. Enable the `pg_diskann` extension and create a DiskANN index to accelerate cosine similarity queries:

    ```sql
    CREATE EXTENSION IF NOT EXISTS pg_diskann;
    CREATE INDEX IF NOT EXISTS cases_cosine_diskann
      ON cases USING diskann(opinions_vector vector_cosine_ops);
    ```

5. Inspect a sample vector to verify the data populated correctly:

    ```sql
    SELECT opinions_vector FROM cases LIMIT 1;
    ```

### Perform a semantic search query

Use the cosine-distance operator (`<=>`) to compare the query embedding against stored vectors:

```sql
SELECT id, name
FROM cases
ORDER BY opinions_vector <=> azure_openai.create_embeddings(
    'text-embedding-3-small',
    'Water leaking into the apartment from the floor above.'
)::vector
LIMIT 10;
```

Results highlight cases with similar semantics even when they do not contain the exact phrase. To inspect the top match in detail:

```sql
SELECT id, opinion
FROM cases
ORDER BY opinions_vector <=> azure_openai.create_embeddings(
    'text-embedding-3-small',
    'Water leaking into the apartment from the floor above.'
)::vector
LIMIT 1;
```

The returned narrative typically references water damage from an upstairs unit, demonstrating why embeddings capture better context than literal `ILIKE` filters.

---

# Part 3 - Build the Agentic App

The notebook in `Code/lab.ipynb` guides you through constructing the Microsoft Agent Framework solution using the resources you provisioned.

## Open the notebook

1. In VS Code, switch back to the Explorer view.
2. Expand the `Code` folder and open `lab.ipynb`.
3. Follow the inline instructions. The notebook reads configuration from the `.env` file generated after `azd up`, so confirm that file exists before executing the cells.

Continue working through the notebook to finish the Agentic App portion of the lab.