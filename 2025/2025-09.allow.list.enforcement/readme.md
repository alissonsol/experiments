# Application allow list enforcement

Complimentary mermaid diagrams to the blog post [Application allow list enforcement](https://alissonsol.blogspot.com/2025/10/application-allow-list-enforcement.html). If the diagrams are shown as text due to the GitHub plug-in not working for your machine, please copy and paste the diagram to sites like [Mermaid.Live](https://mermaid.live/).

## High-level workflow for allow list maintenance

The workflow for [Figure 1](https://alissonsol.blogspot.com/2025/10/application-allow-list-enforcement.html)

```mermaid
flowchart LR
    UX_APP[[Application]] -->|Starts| UX_EA[[Endpoint<br>Agent]]
    DASH[/Dashboards/]
    EV_S[/Risk<br>Score<br>Services/]
    subgraph Databases
        direction LR
        DB_APP[(Application<br>Database)]
        DB_EX[(Execution<br>Database)]
        DB_POL[(Policies<br>Database)]
        DB_APP -->|Aggregation| DASH
        DB_EX -->|Summary| DASH
        DB_POL -->|Review| DASH
    end
    subgraph Endpoint_Execution
        direction LR
            UX_EA -->|Check<br>Policies| UX_DB_APP{Is application<br>in the<br>allow list?}
            UX_DB_APP <--> DB_APP
            UX_DB_APP --> |Yes| UX_R1[[Running<br>Application]]
            UX_DB_APP --> |No| UX_X1[[Execution<br>Blocked]]
            UX_R1 -->|Execution<br>Allowed| DB_EX
            UX_X1 -->|Execution<br>Blocked| DB_EX
            UX_X1 --> |Logs| UX_Q1{Evaluated?}
            UX_Q1 --> |Yes| UX_DY[[Show<br>Decision]]
            UX_DY --> |Appeal<br>Process| UX_DN
            UX_Q1 --> |No| UX_DN[[Evaluation<br>Intake]]
    end
    subgraph Risk_Evaluation
        direction LR
        UX_DN -->|Deduplication| IN_RS{High<br>Risk<br>Scores?}
        IN_RS <--> EV_S
        IN_RS -->|Risky| IN_NO([Rejected])
        IN_RS -->|Not<br>Risky| IN_RE[[Risk<br>Evaluation<br>Committee]]
        IN_RE -->|Votes| IN_CD{Committee<br>Decision?}
        IN_CD -->|Reject| IN_NO
        IN_CD -->|Approve| IN_YES([Approved])
        IN_NO --> DB_APP[(Application<br>Database)]
        IN_YES --> DB_APP
    end
    subgraph Policy_Publishing
        direction LR
        DB_POL <--> |Push<br>Pull| UX_EA[[Endpoint<br>Agent]]
        PB_PU -->|Data<br>Transformation| DB_POL
        DB_APP[(Application<br>Database)] --> |Time| PB_PU[[Policy<br>Updates]]
    end
    subgraph Rescan_and_Governance
        direction LR
        DB_APP[(Application<br>Database)] --> |Time| RS_S[[Rescan]]
        RS_S <--> EV_S
        RS_S[[Rescan]] -->|Review<br>Lists| RS_GC[[Governance<br>Committee]]
        RS_GC -->|Votes| RS_GCD{Governance<br>Committee<br>Decision?}
        RS_GCD -->|Reject| RS_NO([Rejected])
        RS_GCD -->|Approve| RS_YES([Approved])
        RS_NO --> DB_APP
        RS_YES --> DB_APP
    end
```

## Endpoint execution workflow

The workflow for [Figure 2](https://alissonsol.blogspot.com/2025/10/application-allow-list-enforcement.html)

```mermaid
flowchart LR
    UX_APP[[Application]] -->|Starts| UX_EA[[Endpoint<br>Agent]]
        DB_APP[(Application<br>Database)]
        DB_EX[(Execution<br>Database)]
            UX_EA -->|Check<br>Policies| UX_DB_APP{Is application<br>in the<br>allow list?}
            UX_DB_APP <--> DB_APP
            UX_DB_APP --> |Yes| UX_R1[[Running<br>Application]]
            UX_DB_APP --> |No| UX_X1[[Execution<br>Blocked]]
            UX_R1 -->|Execution<br>Allowed| DB_EX
            UX_X1 -->|Execution<br>Blocked| DB_EX
            UX_X1 --> |Logs| UX_Q1{Evaluated?}
            UX_Q1 --> |Yes| UX_DY[[Show<br>Decision]]
            UX_DY --> |Appeal<br>Process| UX_DN
            UX_Q1 --> |No| UX_DN[[Evaluation<br>Intake]]
```

## Risk evaluation workflow

The workflow for [Figure 3](https://alissonsol.blogspot.com/2025/10/application-allow-list-enforcement.html)

```mermaid
flowchart LR
    EV_S[/Risk<br>Score<br>Services/]
        DB_APP[(Application<br>Database)]
        UX_DN[[Evaluation<br>Intake]] -->|Deduplication| IN_RS{High<br>Risk<br>Scores?}
        IN_RS <--> EV_S
        IN_RS -->|Risky| IN_NO([Rejected])
        IN_RS -->|Not<br>Risky| IN_RE[[Risk<br>Evaluation<br>Committee]]
        IN_RE -->|Votes| IN_CD{Committee<br>Decision?}
        IN_CD -->|Reject| IN_NO
        IN_CD -->|Approve| IN_YES([Approved])
        IN_NO --> DB_APP[(Application<br>Database)]
        IN_YES --> DB_APP
```

## Policy publishing workflow

The workflow for [Figure 4](https://alissonsol.blogspot.com/2025/10/application-allow-list-enforcement.html)

```mermaid
flowchart LR
        DB_APP[(Application<br>Database)]
        DB_POL[(Policies<br>Database)]
        DB_POL <--> |Push<br>Pull| UX_EA[[Endpoint<br>Agent]]
        PB_PU -->|Data<br>Transformation| DB_POL
        DB_APP[(Application<br>Database)] --> |Time| PB_PU[[Policy<br>Updates]]
```

## Rescan and governance workflow

The workflow for [Figure 5](https://alissonsol.blogspot.com/2025/10/application-allow-list-enforcement.html)

```mermaid
flowchart LR
    EV_S[/Risk<br>Score<br>Services/]
        DB_APP[(Application<br>Database)]
        DB_APP[(Application<br>Database)] --> |Time| RS_S[[Rescan]]
        RS_S <--> EV_S
        RS_S[[Rescan]] -->|Review<br>Lists| RS_GC[[Governance<br>Committee]]
        RS_GC -->|Votes| RS_GCD{Governance<br>Committee<br>Decision?}
        RS_GCD -->|Reject| RS_NO([Rejected])
        RS_GCD -->|Approve| RS_YES([Approved])
        RS_NO --> DB_APP
        RS_YES --> DB_APP
```