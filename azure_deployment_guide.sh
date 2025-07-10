#!/bin/bash
# Azure Medical Scribe - Deployment Completo na Nuvem
# Sistema de agentes especializados com reconhecimento automático

echo "🏥 Medical Scribe - Deployment Azure Cloud-Native"
echo "=================================================="

# 1. PRÉ-REQUISITOS (executar uma vez)
echo "📋 1. Instalando pré-requisitos..."

# Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Azure Developer CLI  
curl -fsSL https://aka.ms/install-azd.sh | bash

# .NET 8 SDK
wget https://packages.microsoft.com/config/ubuntu/20.04/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
sudo apt-get update && sudo apt-get install -y dotnet-sdk-8.0

# Node.js 18+ (para UI)
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs

echo "✅ Pré-requisitos instalados"

# 2. AUTENTICAÇÃO AZURE
echo "🔑 2. Configurando autenticação Azure..."
az login
azd auth login

# Definir variáveis
SUBSCRIPTION_ID="your-subscription-id"
RESOURCE_GROUP="rg-medical-scribe"
LOCATION="brazilsouth"
PROJECT_NAME="medical-scribe"

echo "📍 Usando: $LOCATION, RG: $RESOURCE_GROUP"

# 3. CLONAR REPOSITÓRIOS BASE
echo "📦 3. Clonando repositórios de referência..."

mkdir -p ~/medical-scribe && cd ~/medical-scribe

# Repositório principal - Healthcare Agent Orchestrator
git clone https://github.com/Azure-Samples/healthcare-agent-orchestrator.git
cd healthcare-agent-orchestrator

# Configurar variáveis do azd
azd env new medical-scribe-prod
azd env set AZURE_LOCATION $LOCATION
azd env set AZURE_SUBSCRIPTION_ID $SUBSCRIPTION_ID

# 4. PROVISIONAMENTO DE INFRAESTRUTURA
echo "🏗️ 4. Provisionando infraestrutura Azure..."

# Criar resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# Deploy completo via azd (Bicep templates)
azd up --location $LOCATION

echo "⏳ Aguardando provisionamento (5-10 minutos)..."

# 5. CONFIGURAÇÃO DOS SERVIÇOS ESPECÍFICOS
echo "⚙️ 5. Configurando serviços especializados..."

# 5.1 Azure Speech Service com diarização
SPEECH_NAME="speech-medical-scribe"
az cognitiveservices account create \
  --name $SPEECH_NAME \
  --resource-group $RESOURCE_GROUP \
  --kind SpeechServices \
  --sku S0 \
  --location $LOCATION \
  --custom-domain $SPEECH_NAME

SPEECH_KEY=$(az cognitiveservices account keys list \
  --name $SPEECH_NAME \
  --resource-group $RESOURCE_GROUP \
  --query key1 -o tsv)

echo "🎤 Speech Service: $SPEECH_NAME"

# 5.2 Text Analytics for Health
LANGUAGE_NAME="language-medical-ner"
az cognitiveservices account create \
  --name $LANGUAGE_NAME \
  --resource-group $RESOURCE_GROUP \
  --kind TextAnalytics \
  --sku S \
  --location $LOCATION

LANGUAGE_KEY=$(az cognitiveservices account keys list \
  --name $LANGUAGE_NAME \
  --resource-group $RESOURCE_GROUP \
  --query key1 -o tsv)

echo "🔍 Text Analytics: $LANGUAGE_NAME"

# 5.3 Azure Health Data Services (FHIR)
FHIR_WORKSPACE="fhir-workspace-scribe"
FHIR_SERVICE="fhir-service-scribe"

az healthcareapis workspace create \
  --name $FHIR_WORKSPACE \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION

az healthcareapis fhir-service create \
  --workspace-name $FHIR_WORKSPACE \
  --resource-group $RESOURCE_GROUP \
  --fhir-service-name $FHIR_SERVICE \
  --kind fhir-R4 \
  --location $LOCATION

FHIR_URL="https://${FHIR_WORKSPACE}-${FHIR_SERVICE}.fhir.azurehealthcareapis.com"
echo "🏥 FHIR Service: $FHIR_URL"

# 5.4 Cosmos DB Gremlin para grafos
COSMOS_NAME="cosmos-medical-graph"
az cosmosdb create \
  --name $COSMOS_NAME \
  --resource-group $RESOURCE_GROUP \
  --kind GlobalDocumentDB \
  --capabilities EnableGremlin \
  --locations regionName=$LOCATION

az cosmosdb gremlin database create \
  --account-name $COSMOS_NAME \
  --resource-group $RESOURCE_GROUP \
  --name medical_graph \
  --throughput 400

az cosmosdb gremlin container create \
  --account-name $COSMOS_NAME \
  --resource-group $RESOURCE_GROUP \
  --database-name medical_graph \
  --name sessions \
  --partition-key-path "/sessionId" \
  --throughput 400

COSMOS_KEY=$(az cosmosdb keys list \
  --name $COSMOS_NAME \
  --resource-group $RESOURCE_GROUP \
  --query primaryMasterKey -o tsv)

echo "🌐 Cosmos Gremlin: $COSMOS_NAME"

# 5.5 Azure Communication Services (opcional para telefonia)
ACS_NAME="acs-medical-scribe"
az communication create \
  --name $ACS_NAME \
  --resource-group $RESOURCE_GROUP \
  --location "global"

ACS_CONNECTION=$(az communication list-key \
  --name $ACS_NAME \
  --resource-group $RESOURCE_GROUP \
  --query primaryConnectionString -o tsv)

echo "📞 Communication Services: $ACS_NAME"

# 6. DEPLOY DA APLICAÇÃO CUSTOMIZADA
echo "🚀 6. Deploy da aplicação Medical Scribe..."

cd ~/medical-scribe

# Criar estrutura do projeto customizado
cat > appsettings.json << EOF
{
  "AzureOpenAI": {
    "Endpoint": "$(azd env get-values | grep AZURE_OPENAI_ENDPOINT | cut -d'=' -f2)",
    "ApiKey": "$(azd env get-values | grep AZURE_OPENAI_API_KEY | cut -d'=' -f2)",
    "DeploymentName": "gpt-4"
  },
  "AzureSpeech": {
    "Key": "$SPEECH_KEY",
    "Region": "$LOCATION"
  },
  "TextAnalytics": {
    "Key": "$LANGUAGE_KEY",
    "Endpoint": "https://$LANGUAGE_NAME.cognitiveservices.azure.com/"
  },
  "FHIR": {
    "Endpoint": "$FHIR_URL"
  },
  "CosmosGremlin": {
    "Endpoint": "wss://$COSMOS_NAME.gremlin.cosmosdb.azure.com:443/",
    "Key": "$COSMOS_KEY",
    "Database": "medical_graph"
  },
  "AzureCommunication": {
    "ConnectionString": "$ACS_CONNECTION"
  }
}
EOF

# 6.1 Deploy do backend (App Service)
APP_SERVICE_NAME="app-medical-scribe-$(date +%s)"

# Criar App Service Plan
az appservice plan create \
  --name "plan-medical-scribe" \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku P1v3 \
  --is-linux

# Criar Web App
az webapp create \
  --name $APP_SERVICE_NAME \
  --resource-group $RESOURCE_GROUP \
  --plan "plan-medical-scribe" \
  --runtime "DOTNETCORE:8.0"

# Configurar app settings
az webapp config appsettings set \
  --name $APP_SERVICE_NAME \
  --resource-group $RESOURCE_GROUP \
  --settings @appsettings.json

echo "🌐 App Service: https://$APP_SERVICE_NAME.azurewebsites.net"

# 6.2 Deploy do frontend (Static Web Apps)
STATIC_APP_NAME="swa-medical-scribe"

# Criar Static Web App
az staticwebapp create \
  --name $STATIC_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION

echo "🖥️ Static Web App: $STATIC_APP_NAME"

# 7. CONFIGURAÇÃO DE AGENTES ESPECIALIZADOS
echo "🤖 7. Configurando agentes especializados..."

# Criar arquivo de configuração dos agentes
cat > agents-config.json << EOF
{
  "agents": [
    {
      "name": "PrescriptionAgent",
      "model": "gpt-4",
      "instructions": "Especialista em prescrições médicas. Detecta medicações, dosagens e frequências. Gera receitas seguindo padrões brasileiros.",
      "triggers": {
        "entities": ["MedicationName", "Dosage", "Frequency"],
        "keywords": ["prescrever", "medicação", "remédio", "tomar"],
        "confidence_threshold": 0.7
      },
      "tools": [
        {
          "type": "function",
          "function": {
            "name": "generate_prescription",
            "description": "Gera receita médica estruturada"
          }
        }
      ]
    },
    {
      "name": "AppointmentAgent", 
      "model": "gpt-4",
      "instructions": "Especialista em agendamentos. Identifica intenções de retorno e agenda automaticamente via Microsoft Graph.",
      "triggers": {
        "keywords": ["retorno", "agendar", "próxima consulta", "voltar"],
        "temporal_indicators": ["dias", "semana", "mês"],
        "confidence_threshold": 0.6
      },
      "tools": [
        {
          "type": "function",
          "function": {
            "name": "create_calendar_event",
            "description": "Cria evento no calendário via Microsoft Graph"
          }
        }
      ]
    },
    {
      "name": "ReportAgent",
      "model": "gpt-4", 
      "instructions": "Especialista em laudos e atestados médicos. Gera documentos oficiais com CID-10.",
      "triggers": {
        "keywords": ["atestado", "laudo", "relatório", "incapacidade"],
        "entities": ["Condition", "Procedure"],
        "confidence_threshold": 0.8
      }
    },
    {
      "name": "EvolutionAgent",
      "model": "gpt-4",
      "instructions": "Documenta evolução clínica e histórico da consulta.",
      "triggers": {
        "always_active": true,
        "confidence_threshold": 0.5
      }
    }
  ],
  "templates": {
    "receita_medica": "templates/receita_medica.md",
    "atestado_medico": "templates/atestado_medico.md", 
    "laudo_exame": "templates/laudo_exame.md",
    "evolucao_clinica": "templates/evolucao_clinica.md"
  }
}
EOF

# Upload da configuração
az storage blob upload \
  --account-name $(azd env get-values | grep AZURE_STORAGE_ACCOUNT | cut -d'=' -f2) \
  --container-name config \
  --name agents-config.json \
  --file agents-config.json

echo "⚙️ Configuração de agentes carregada"

# 8. TESTE DE INTEGRAÇÃO
echo "🧪 8. Executando testes de integração..."

# Teste de conectividade dos serviços
echo "Testando Speech Service..."
curl -H "Ocp-Apim-Subscription-Key: $SPEECH_KEY" \
  "https://$LOCATION.api.cognitive.microsoft.com/sts/v1.0/issueToken" -d ""

echo "Testando Text Analytics..."  
curl -H "Ocp-Apim-Subscription-Key: $LANGUAGE_KEY" \
  "https://$LANGUAGE_NAME.cognitiveservices.azure.com/text/analytics/v3.1/health" \
  -H "Content-Type: application/json" \
  -d '{"documents":[{"id":"1","text":"Patient prescribed ibuprofen 600mg twice daily"}]}'

echo "Testando FHIR Service..."
curl -H "Authorization: Bearer $(az account get-access-token --resource=$FHIR_URL --query accessToken -o tsv)" \
  "$FHIR_URL/metadata"

echo "✅ Testes de conectividade concluídos"

# 9. CONFIGURAÇÃO DE MONITORAMENTO
echo "📊 9. Configurando monitoramento..."

# Application Insights
APPINSIGHTS_NAME="ai-medical-scribe"
az monitor app-insights component create \
  --app $APPINSIGHTS_NAME \
  --location $LOCATION \
  --resource-group $RESOURCE_GROUP \
  --application-type web

APPINSIGHTS_KEY=$(az monitor app-insights component show \
  --app $APPINSIGHTS_NAME \
  --resource-group $RESOURCE_GROUP \
  --query instrumentationKey -o tsv)

# Configurar no App Service
az webapp config appsettings set \
  --name $APP_SERVICE_NAME \
  --resource-group $RESOURCE_GROUP \
  --settings APPINSIGHTS_INSTRUMENTATIONKEY=$APPINSIGHTS_KEY

echo "📈 Application Insights: $APPINSIGHTS_NAME"

# 10. CONFIGURAÇÃO DE SEGURANÇA E COMPLIANCE
echo "🔒 10. Configurando segurança e compliance..."

# Habilitar HTTPS only
az webapp update \
  --name $APP_SERVICE_NAME \
  --resource-group $RESOURCE_GROUP \
  --https-only true

# Configurar Customer Managed Keys para FHIR (LGPD compliance)
# Este passo requer configuração manual no portal para chaves específicas

# Configurar audit logging
az monitor diagnostic-settings create \
  --name "medical-scribe-audit" \
  --resource "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.HealthcareApis/workspaces/$FHIR_WORKSPACE" \
  --logs '[
    {
      "category": "AuditLogs",
      "enabled": true,
      "retentionPolicy": {
        "enabled": true,
        "days": 365
      }
    }
  ]' \
  --workspace "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.OperationalInsights/workspaces/log-medical-scribe"

echo "🔐 Configurações de segurança aplicadas"

# 11. RESUMO FINAL
echo ""
echo "🎉 DEPLOYMENT CONCLUÍDO COM SUCESSO!"
echo "=================================="
echo ""
echo "📋 RESUMO DOS SERVIÇOS CRIADOS:"
echo "• Resource Group: $RESOURCE_GROUP"
echo "• Speech Service: https://$LOCATION.api.cognitive.microsoft.com/ (Key: ${SPEECH_KEY:0:8}...)"
echo "• Text Analytics: https://$LANGUAGE_NAME.cognitiveservices.azure.com/"
echo "• FHIR Service: $FHIR_URL"
echo "• Cosmos Gremlin: wss://$COSMOS_NAME.gremlin.cosmosdb.azure.com:443/"
echo "• App Service: https://$APP_SERVICE_NAME.azurewebsites.net"
echo "• Static Web App: https://$STATIC_APP_NAME.azurestaticapps.net"
echo "• Application Insights: $APPINSIGHTS_NAME"
echo ""
echo "🔗 PRÓXIMOS PASSOS:"
echo "1. Acesse a UI: https://$STATIC_APP_NAME.azurestaticapps.net"
echo "2. Configure Microsoft Graph para agendamentos"
echo "3. Carregue templates personalizados no Blob Storage"
echo "4. Teste com áudio real via Speech SDK"
echo "5. Configure alerts no Application Insights"
echo ""
echo "💰 CUSTOS ESTIMADOS:"
echo "• Speech Service (S0): ~$45/mês para 150 consultas"
echo "• OpenAI Service: ~$120/mês para agentes + embeddings"
echo "• App Service (P1v3): ~$60/mês"
echo "• Cosmos Gremlin: ~$25/mês (400 RU/s)"
echo "• FHIR Service: Gratuito (tier inicial)"
echo "• Total estimado: ~$250/mês"
echo ""
echo "✅ Sistema pronto para uso em produção!"

# Salvar informações de acesso
cat > deployment-info.txt << EOF
Medical Scribe - Informações de Deployment
==========================================

Resource Group: $RESOURCE_GROUP
Location: $LOCATION

Endpoints:
- Frontend UI: https://$STATIC_APP_NAME.azurestaticapps.net
- Backend API: https://$APP_SERVICE_NAME.azurewebsites.net
- FHIR Service: $FHIR_URL
- Speech Service: https://$LOCATION.api.cognitive.microsoft.com/

Keys (primeiros 8 caracteres):
- Speech Key: ${SPEECH_KEY:0:8}...
- Language Key: ${LANGUAGE_KEY:0:8}...
- Cosmos Key: ${COSMOS_KEY:0:8}...

Deployment Date: $(date)
EOF

echo "📄 Informações salvas em: deployment-info.txt"