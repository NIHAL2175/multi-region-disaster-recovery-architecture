# PaySecure Gateway: Cross-Region Data Flow & Security Boundary Diagrams

**Document ID**: PSG-GRC-002-FLOW  
**Compliance Standard**: RBI Data Localisation Directive & PCI-DSS v4.0 CDE Scoping  

---

## 1. Cross-Region Data Flow & Encryption Boundaries

This diagram details the physical and logical flow of payment transactions, showing encryption algorithms, network boundaries, and statutory domestic containment within Indian borders.

```mermaid
graph TD
    subgraph Public_Internet["Public Internet (Indian Consumers & Merchants)"]
        Merchant[Merchant Client Application]
        Consumer[Consumer Mobile UPI App]
    end

    subgraph AWS_Mumbai["AWS ap-south-1 (Mumbai Region) - Sovereign Indian Soil"]
        ALB_MUM["Public ALB + AWS WAFv2<br/>(TLS 1.3 / Port 443)"]
        
        subgraph EKS_MUM["Amazon EKS Cluster (paysecure-mumbai)"]
            API_MUM["payment-api Pods"]
            TXN_MUM["transaction-processor Pods"]
            
            subgraph CDE_MUM["PCI-DSS CDE Boundary (paysecure-cde)"]
                TOKEN_MUM["tokenisation-service<br/>(mTLS gRPC Port 8443)"]
            end
        end
        
        KMS_MUM[("AWS KMS Multi-Region Primary<br/>mrk-cde-mumbai-master<br/>AES-256 Envelope")]
        AURORA_MUM[("Aurora PG Writer Cluster<br/>AES-256 Storage Encrypted")]
        DYNAMO_MUM[("DynamoDB Global Table<br/>paysecure-sessions")]
        MSK_MUM["Amazon MSK Kafka<br/>TLS 1.3 Encrypted"]
    end

    subgraph AWS_Hyderabad["AWS ap-south-2 (Hyderabad Region) - Sovereign Indian Soil"]
        ALB_HYD["Public Standby ALB<br/>(Route 53 Standby Target)"]
        
        subgraph EKS_HYD["Amazon EKS Standby Cluster (paysecure-hyd)"]
            API_HYD["payment-api Pods (30% Standby)"]
            TXN_HYD["transaction-processor Pods"]
            
            subgraph CDE_HYD["PCI-DSS CDE Boundary (Standby)"]
                TOKEN_HYD["tokenisation-service (Standby)"]
            end
        end
        
        KMS_HYD[("AWS KMS Multi-Region Replica<br/>mrk-cde-hyd-replica<br/>AES-256 Compatible")]
        AURORA_HYD[("Aurora PG Reader Replica<br/>Promotable to Writer in 75s")]
        DYNAMO_HYD[("DynamoDB Global Replica<br/>Replication Lag < 800ms")]
        MSK_HYD["Amazon MSK Kafka Standby<br/>Target of MSK Replicator"]
    end

    %% Ingress Flow
    Merchant -->|HTTPS TLS 1.3| ALB_MUM
    Consumer -->|HTTPS TLS 1.3| ALB_MUM
    ALB_MUM -->|HTTP/2 mTLS| API_MUM
    API_MUM --> TXN_MUM
    TXN_MUM -->|mTLS Port 8443| TOKEN_MUM
    TOKEN_MUM <-->|Encrypt / Decrypt| KMS_MUM
    TXN_MUM -->|ACID Commit| AURORA_MUM
    API_MUM -->|Idempotency Lease| DYNAMO_MUM
    TXN_MUM -->|Publish Event| MSK_MUM

    %% Dedicated Cross-Region AWS Private Backbone (Zero Public Internet)
    AURORA_MUM ==>|Aurora Storage Replication < 650ms| AURORA_HYD
    DYNAMO_MUM -.->|Bi-directional DynamoDB Sync < 800ms| DYNAMO_HYD
    MSK_MUM ==>|AWS MSK Replicator Stream| MSK_HYD
    KMS_MUM <==>|AWS Inter-Region Private Key Sync| KMS_HYD

    %% Styling
    classDef indian fill:#E8F5E9,stroke:#2E7D32,stroke-width:2px;
    classDef cde fill:#FFEBEE,stroke:#C62828,stroke-width:2px,stroke-dasharray: 5 5;
    classDef storage fill:#FFF8E1,stroke:#FFA000,stroke-width:1.5px;
    
    class AWS_Mumbai,AWS_Hyderabad indian;
    class CDE_MUM,CDE_HYD cde;
    class AURORA_MUM,AURORA_HYD,DYNAMO_MUM,DYNAMO_HYD,KMS_MUM,KMS_HYD storage;
```

---

## 2. Cardholder Data Isolation & Tokenization Boundary

The tokenization workflow guarantees that raw Primary Account Numbers (PAN) and CVVs are strictly confined to the in-memory boundary of the `tokenisation-service`:

```mermaid
sequenceDiagram
    autonumber
    participant Client as Merchant Checkout
    participant API as payment-api (General Pod)
    participant CDE as tokenisation-service (PCI-DSS CDE)
    participant KMS as AWS KMS (mrk-cde-mumbai)
    participant DB as Aurora PostgreSQL (Card Vault)
    participant Bank as Acquiring Bank / Card Network

    Client->>API: POST /api/v1/payments (Encrypted Card Payload)
    Note over API: General VPC Subnet (Non-CDE)
    API->>CDE: gRPC tokenize() over mTLS (Port 8443)
    Note over CDE: Isolated CDE Namespace (paysecure-cde)
    CDE->>KMS: GenerateDataKey(KeyId=mrk-cde-mumbai)
    KMS-->>CDE: Plaintext Data Key + Ciphertext Data Key
    
    Note over CDE: AES-256-GCM Encrypt PAN with Plaintext Key
    Note over CDE: Memory zeroization of Plaintext Data Key
    
    CDE->>DB: INSERT INTO card_vault (token, encrypted_pan, encrypted_data_key)
    DB-->>CDE: 201 Created (Token: TOK_CC_998812)
    CDE-->>API: Return Token: TOK_CC_998812
    
    API->>Bank: Submit Payment Auth with Card Token
    Bank-->>API: Payment Approved
    API-->>Client: HTTP 200 OK (Zero raw card data stored in application tier)
```
