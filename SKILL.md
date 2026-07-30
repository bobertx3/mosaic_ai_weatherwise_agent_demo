# bobertx3 Project Skill

When building a **bobertx3 project**, follow these conventions for repo structure, agent design, and UI design. Every project should feel like a polished, demo-ready Databricks app with consistent patterns across the board.

---

## Repo Structure

Every bobertx3 project follows this top-level layout:

```
/
├── agent_src/                    # Core agent logic
│   ├── <agent_name>.py           # Main LangGraph agent (system prompt, tools, graph)
│   ├── agent_eval_notebook.ipynb # MLflow eval, registration, and deployment
│   └── tools/
│       ├── uc_tools/             # Unity Catalog function & vector index notebooks
│       └── custom_tools/         # Python tool implementations (APIs, integrations)
├── chatapp/                      # Databricks App (Node.js/React monorepo)
│   ├── app.yaml                  # Databricks App config
│   ├── client/                   # React frontend (Vite + TailwindCSS)
│   ├── server/                   # Express backend (TypeScript)
│   ├── packages/                 # Shared packages (core, auth, db, utils, ai-sdk-providers)
│   └── scripts/                  # DB migrations, start scripts
├── data/                         # Demo data (CSVs) + setup notebook
│   ├── setup_data.ipynb          # Loads CSVs → Delta tables, creates UC assets
│   └── *.csv                     # Demo datasets
├── genie/                        # Genie Space setup scripts (optional)
├── img/                          # Screenshots, flow diagrams, architecture diagrams
├── tests/                        # Manual tool testing notebooks
├── .env / _env                   # Environment variables (template in _env, secrets in .env)
├── setup.sh                      # One-shot setup script (data + UC assets + agent deploy)
├── databricks.yml                # Databricks Asset Bundle config
└── README.md                     # Project documentation
```

### Key Conventions

- **`_env`** is the committed template. **`.env`** is `.gitignored` with real secrets.
- **`setup.sh`** is a comprehensive bash script that automates the entire setup: data loading, UC function creation, vector search index, agent registration, and deployment. It should support `--cluster-id` and `--manual` flags.
- **`data/`** always contains CSV demo datasets and a `setup_data.ipynb` notebook.
- **`img/`** always contains: `agent_flow.png`, `arch.png`, `manual_flow.png`, and numbered screenshots (`01_*.png`, `02_*.png`, etc.) for the README walkthrough.
- **`tests/`** contains a `manually_test_tools.ipynb` for validating individual tools before running the full agent.

---

## Agent Design

### Architecture Pattern

- **LangGraph** with `ChatAgentState` and `ChatAgentToolNode` from MLflow
- Single orchestrator agent with a system prompt that defines **multiple personas** (sub-agents) — e.g., Analyst, Researcher, Copywriter, Notifier
- Tool-calling loop: `agent → should_continue? → tools → agent`
- Recursion limit set to 60 at execution time

### Tool Categories

1. **UC Functions** — SQL-backed tools registered in Unity Catalog (querying tables, calculations)
2. **Vector Search** — `VectorSearchRetrieverTool` for RAG over documents/SOPs
3. **Custom Python Tools** — External API integrations (weather, email, SMS, etc.)

### System Prompt Structure

```
You are the [Domain] [Role] Crew of Agents.

GOAL
[High-level mission]

---

[PERSONA 1]
Role: ...
Goal: ...
Tools: ...

---

[PERSONA N]
...

---

OPERATING PRINCIPLES
- Be concise, factual, action-oriented
- Never output raw tool results without a professional summary
- Do not fabricate data

---

DECISION POLICY
[Domain-specific classification logic]

---

GUARDRAILS
[Safety and scope boundaries]
```

### MLflow Integration

- `mlflow.langchain.autolog()` for tracing
- `LangGraphChatAgent(ChatAgent)` wrapper with `predict()` and `predict_stream()`
- Register to Unity Catalog, deploy via Model Serving

---

## Agent Eval Notebook (`agent_eval_notebook.ipynb`)

Every bobertx3 project includes a **single eval notebook** that handles the full agent lifecycle: test, evaluate, register, and deploy. The notebook follows this exact cell sequence:

### Cell Structure

#### Header Cell (Markdown)
Document the **Mosaic AI Core APIs** used in the project as a quick reference:
- MLflow model lifecycle (`log_model`, `register_model`, `load_model`, `set_experiment`, `@mlflow.trace`)
- MLflow GenAI evaluation (`mlflow.genai.evaluate`, scorers, datasets)
- Databricks Agent Framework (`agents.deploy`, `agents.list_deployments`)
- Unity Catalog tools (`DatabricksFunctionClient`, `create_python_function`)
- Runtime execution (`mlflow.models.predict`, `spark_udf`)

#### Step 1: Install & Setup
```python
%pip install -U -qqqq mlflow-skinny[databricks] langgraph==0.3.4 databricks-langchain databricks-agents langchain-openai twilio python-dotenv
dbutils.library.restartPython()
```
- `%load_ext autoreload` + `%autoreload 2` for hot-reloading agent code
- `sys.path.append("./tools")` to make custom tools importable

#### Step 2: Load Environment & Verify
```python
import weatherwise_agent  # import the agent module
load_dotenv(find_dotenv())

# Print all tool names
tool_names = [t.name for t in weatherwise_agent.tools]

# Load ALL env vars into notebook variables
# Print them with redaction for secrets
def redact(val, show=4): ...
```
**Key pattern**: Always print available tools and redacted env vars for quick verification.

#### Step 3: Create MLflow Experiment
```python
user = spark.sql("select current_user()").first()[0]
exp_path = f"/Users/{user}/{MLFLOW_EXPERIMENT}"
mlflow.end_run()  # end any stray runs
mlflow.set_experiment(exp_path)
```

#### Step 4: Unit Test the Agent
Run a single comprehensive query that exercises **all tools and personas** in one shot:
```python
from weatherwise_agent import AGENT

response = AGENT.predict({
    "messages": [{
        "role": "user",
        "content": "<complex query that triggers ALL agent capabilities>"
    }]
})
display(response)
```
The test query should be a "full automation" scenario — touching weather, data retrieval, supplier lookup, email, and SMS all at once.

#### Step 5: Log Model to MLflow
```python
from mlflow.models.resources import DatabricksFunction, DatabricksServingEndpoint

# Auto-discover resources from tools
resources = [DatabricksServingEndpoint(endpoint_name=LLM_ENDPOINT_NAME)]
for tool in tools:
    if isinstance(tool, VectorSearchRetrieverTool):
        resources.extend(tool.resources)
    elif isinstance(tool, UnityCatalogTool):
        resources.append(DatabricksFunction(function_name=tool.uc_function_name))

with mlflow.start_run(run_name=f"{AGENT_NAME}-ut-{datetime.datetime.now():%Y%m%d}"):
    logged_agent_info = mlflow.pyfunc.log_model(
        name=AGENT_NAME,
        python_model="<agent_file>.py",
        input_example=input_example,
        resources=resources,
        code_paths=["tools/custom_tools/"],
    )
```
**Key patterns**:
- Run name includes date suffix: `{agent}-ut-{YYYYMMDD}`
- Auto-discover resources by iterating `tools` and checking types (`VectorSearchRetrieverTool`, `UnityCatalogTool`)
- `code_paths` includes custom tools directory

#### Step 6: Create Prediction Wrapper
```python
logged_model_uri = f"runs:/{logged_agent_info.run_id}/{AGENT_NAME}"
loaded_model = mlflow.pyfunc.load_model(logged_model_uri)

def predict_wrapper(query):
    model_input = {"messages": [{"role": "user", "content": query}]}
    response = loaded_model.predict(model_input)
    return response['messages'][-1]['content']
```
This wrapper simplifies eval calls — just pass a string query, get a string response.

#### Step 7: Define Eval Dataset
```python
cases = [
    {
        "request": "...",
        "expected_facts": ["fact 1", "fact 2", "..."],
    },
    # ... 10-15 cases covering all tools and edge cases
]

eval_data = [
    {
        "inputs": {"query": row["request"]},
        "expectations": {"expected_facts": row["expected_facts"]},
    }
    for _, row in pd.DataFrame(cases).iterrows()
]
```
**Key patterns**:
- Use `expected_facts` (list of strings) not `expected_response` — allows partial matching
- Cover **every tool** and **every persona** across the eval set
- Include product-specific, supplier-specific, and cross-cutting queries
- 10-15 cases minimum

#### Step 8: Define LLM Judges (Scorers)
```python
from mlflow.genai.scorers import Correctness, Safety, RelevanceToQuery, Guidelines

scorers = [
    Correctness(),         # factual accuracy vs expected_facts
    Safety(),              # harmful/off-policy content
    RelevanceToQuery(),    # response relevance to input
    Guidelines(            # custom domain-specific tone/style
        name="<domain>_tone",
        guidelines="""Professional and concise:
        • No chit-chat or clarifying questions
        • No logs/JSON/system/meta
        Pass if clear, factual, structured; fail if casual/wordy."""
    ),
]
```
**Always include all four**: Correctness, Safety, RelevanceToQuery, and a custom Guidelines scorer for domain tone.

#### Step 9: Run Evals
```python
with mlflow.start_run(run_name=f"{AGENT_NAME}-evals-{datetime.datetime.now():%Y%m%d}"):
    results = mlflow.genai.evaluate(
        data=eval_data,
        predict_fn=predict_wrapper,
        scorers=scorers,
    )
```

#### Step 10: Iterate (Markdown Cell)
> Based on evals go back to the agent code (.py file) and change the prompt to be more specific, add guidelines, reduce marketing fluff, be more actionable, etc.

This is an explicit **pause point** — review eval results before proceeding to registration.

#### Step 11: Register Model to Unity Catalog
```python
uc_model_name = f"{TARGET_CATALOG}.{TARGET_SCHEMA}.{AGENT_NAME}"
uc_registered_model_info = mlflow.register_model(
    model_uri=logged_agent_info.model_uri,
    name=uc_model_name
)
```
Include a clickable HTML link to the UC model page:
```python
workspace_url = spark.conf.get('spark.databricks.workspaceUrl')
html_link = f'<a href="https://{workspace_url}/explore/data/models/{TARGET_CATALOG}/{TARGET_SCHEMA}/{AGENT_NAME}">Go to Unity Catalog</a>'
display(HTML(html_link))
```

#### Step 12: Deploy to Model Serving
```python
from databricks import agents

agents.deploy(
    model_name=uc_model_name,
    model_version=uc_registered_model_info.version,
    scale_to_zero=True,
    environment_vars={
        # ALL env vars the agent needs at serving time
        "TARGET_CATALOG": ...,
        "TARGET_SCHEMA": ...,
        "LLM_ENDPOINT_NAME": ...,
        # ... including API keys for custom tools
    },
    tags={"endpointSource": AGENT_NAME},
)
```
**Key patterns**:
- `scale_to_zero=True` for cost efficiency
- Pass **all** environment variables the agent needs (UC config, LLM endpoint, API keys)
- Tag with `endpointSource` for traceability

### Eval Notebook Summary

| Step | Cell Type | Purpose |
|------|-----------|---------|
| Header | Markdown | API reference cheatsheet |
| 1 | Code | pip install + restart |
| 2 | Code | Load env, verify tools |
| 3 | Code | Create MLflow experiment |
| 4 | Code | Unit test (full automation query) |
| 5 | Code | Log model with auto-discovered resources |
| 6 | Code | Create predict_wrapper |
| 7 | Code | Define eval dataset (expected_facts) |
| 8 | Code | Define 4 scorers (Correctness, Safety, Relevance, Guidelines) |
| 9 | Code | Run mlflow.genai.evaluate |
| 10 | Markdown | Pause — iterate on prompt |
| 11 | Code | Register to Unity Catalog |
| 12 | Code | Deploy via agents.deploy |

---

## UI Design Principles

### App Shell

The chatapp is a **Databricks App** using the standard chat template monorepo with these customizations:

```
React (Vite) + TailwindCSS + shadcn/ui components
├── Dark/light theme via ThemeProvider (system default)
├── Session-based auth via Databricks OAuth
├── react-router-dom for page routing
└── Framer Motion for micro-animations
```

### Navigation — Always Three+ Tabs

The header **always** includes a compact tab bar with at minimum:

| Tab | Purpose |
|-----|---------|
| **Agent** (chat) | Primary chat interface with the AI agent |
| **Dashboard** | Data visualization page showing the domain data the agent works with |
| **Ask Genie** | Genie Space integration for natural-language SQL exploration |

Additional tabs can be added per project. The active tab uses `bg-primary/10 text-primary` styling.

### Agent Flow Button (REQUIRED)

Every project **must** include an **"Agent Flow"** button in the header (right side) that opens a modal visualizing the agent's architecture:

- **`agent-flow-modal.tsx`** — Full-screen modal with:
  - **Row 1**: User Query → Orchestrator (main agent)
  - **Row 2**: Sub-agent grid (3-column layout, color-coded blue)
  - **Row 3**: Tool chips (color-coded by category)
  - **Detail panel**: Clicking any node shows its description and connected tools
  - **Legend**: Color-coded categories (Orchestrator=yellow, Sub-Agent=blue, Custom Tool=green, UC Function=purple, Vector Search=pink)

The data driving this modal is **hardcoded arrays** of `AgentNode[]` and `FlowConnection[]` — no external diagram tool needed. This is interactive and click-explorable.

### Color Coding for Node Categories

| Category | Background | Border |
|----------|------------|--------|
| Orchestrator | `rgba(234, 179, 8, 0.15)` | `#eab308` |
| Sub-Agent | `rgba(59, 130, 246, 0.15)` | `#3b82f6` |
| Custom Tool | `rgba(34, 197, 94, 0.15)` | `#22c55e` |
| UC Function | `rgba(168, 85, 247, 0.15)` | `#a855f7` |
| Vector Search | `rgba(236, 72, 153, 0.15)` | `#ec4899` |

### Greeting Page

New chat shows an animated greeting with:
1. Bold intro line: `"Hello there! I'm the [Agent Name]."`
2. Muted description: What the agent does, domain-specific
3. **Suggested actions** — 4 domain-specific starter prompts in a 2x2 grid with staggered fade-in animations

### Tool Result Renderers

Create **custom React components** for each tool's output, registered in `tool-renderers/index.tsx`:

- A `renderToolOutput(toolName, output)` function that pattern-matches on tool names
- Returns rich cards/tables instead of raw JSON
- Falls back to raw display if unrecognized
- Support both short tool names (`get_shipments`) and fully qualified UC names (`catalog__schema__get_shipments`)

### Dashboard Page

A dedicated data visualization page that:
- Fetches summary data from `/api/dashboard/summary`
- Shows status cards (counts/KPIs at the top)
- Data table for the primary entity
- Grid of secondary visualizations (2-column on large screens)

### Chat Features

- Sidebar with chat history
- Message actions (copy, feedback)
- Tool call visualization with expandable details
- Streaming responses
- Follow-up action suggestions
- Multimodal input support

---

## Databricks Bundle Config

`databricks.yml` follows this pattern:

```yaml
bundle:
  name: <project-name>

workspace:
  root_path: /Workspace/Users/${workspace.current_user.userName}/<project-name>

variables:
  serving_endpoint_name:
    description: "Model serving endpoint"
    default: "<default-endpoint>"
  sql_warehouse_id:
    description: "SQL warehouse for dashboard/Genie"
    default: "<warehouse-id>"
  resource_name_suffix:
    description: "Suffix for resource names"

resources:
  apps:
    <app_name>:
      name: <app-display-name>
      source_code_path: ./chatapp
      resources:
        - name: serving-endpoint
          serving_endpoint:
            name: ${var.serving_endpoint_name}
            permission: CAN_QUERY
        - name: sql-warehouse
          sql_warehouse:
            id: ${var.sql_warehouse_id}
            permission: CAN_USE

targets:
  dev:
    mode: development
    default: true
  staging:
    mode: production
  prod:
    mode: production
```

---

## README Structure

Every README follows this order:

1. **Title** + one-line description
2. **Hero screenshot** (chat landing page)
3. **Mission** statement
4. **Scenario** — Business Process flow diagram + Agent Flow diagram
5. **Architecture** diagram
6. **Example Queries** table
7. **Business Value** (Speed / Savings / Compliance)
8. **Agents & Tools** — Each persona with role, goal, tools
9. **Tools Overview** — UC Tools table + Custom Tools table
10. **Demo Data Sources** table
11. **Installation & Setup** — step-by-step with numbered sections
12. **Repository Structure** tree

---

## Checklist for New Projects

- [ ] `data/` with CSVs and `setup_data.ipynb`
- [ ] `img/` with `agent_flow.png`, `arch.png`, `manual_flow.png`, numbered screenshots
- [ ] `agent_src/` with agent, eval notebook, and tools (UC + custom)
- [ ] `chatapp/` with Agent Flow modal, Dashboard page, Genie page
- [ ] `setup.sh` with full automation
- [ ] `.env` / `_env` template
- [ ] `databricks.yml` with app + serving endpoint + warehouse resources
- [ ] `tests/manually_test_tools.ipynb`
- [ ] README with all sections
- [ ] Tool renderers for each tool output
- [ ] Suggested actions (4 domain-specific prompts)
- [ ] Greeting component customized for the domain
