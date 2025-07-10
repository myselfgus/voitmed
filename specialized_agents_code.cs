// MedicalScribeAgents.cs - Sistema de agentes especializados com triggers automáticos

using Azure.AI.OpenAI;
using Azure.AI.TextAnalytics;
using Microsoft.Graph;
using System.Text.Json;

namespace MedicalScribe.Agents
{
    // 1. ORCHESTRATOR AGENT - Decisor inteligente
    public class OrchestratorAgent
    {
        private readonly OpenAIClient _openAIClient;
        private readonly TextAnalyticsClient _textAnalytics;
        private readonly List<ISpecializedAgent> _specializedAgents;
        
        public OrchestratorAgent(OpenAIClient openAI, TextAnalyticsClient textAnalytics)
        {
            _openAIClient = openAI;
            _textAnalytics = textAnalytics;
            _specializedAgents = new List<ISpecializedAgent>
            {
                new PrescriptionAgent(openAI),
                new AppointmentAgent(openAI),
                new ReportAgent(openAI),
                new EvolutionAgent(openAI)
            };
        }

        public async Task<AgentResponse> ProcessTranscriptionChunk(TranscriptionChunk chunk)
        {
            // 1. Extrair entidades médicas via Text Analytics for Health
            var healthEntities = await ExtractMedicalEntities(chunk.Text);
            
            // 2. Classificar intenções e triggers
            var intentions = await ClassifyIntentions(chunk, healthEntities);
            
            // 3. Disparar agentes especializados em paralelo
            var activatedAgents = _specializedAgents
                .Where(agent => agent.ShouldActivate(intentions, healthEntities))
                .ToList();

            if (activatedAgents.Any())
            {
                var agentTasks = activatedAgents.Select(agent => 
                    agent.ProcessAsync(chunk, healthEntities, intentions));
                
                var results = await Task.WhenAll(agentTasks);
                
                return new AgentResponse
                {
                    TriggeredAgents = activatedAgents.Select(a => a.GetType().Name).ToList(),
                    GeneratedDocuments = results.SelectMany(r => r.Documents).ToList(),
                    Actions = results.SelectMany(r => r.Actions).ToList(),
                    ConfidenceScore = results.Average(r => r.Confidence)
                };
            }

            return new AgentResponse { Message = "Nenhum agente ativado neste contexto." };
        }

        private async Task<List<HealthcareEntity>> ExtractMedicalEntities(string text)
        {
            var documents = new List<TextDocumentInput> { new TextDocumentInput("1", text) };
            var operation = await _textAnalytics.AnalyzeHealthcareEntitiesAsync(documents);
            
            await operation.WaitForCompletionAsync();
            
            var entities = new List<HealthcareEntity>();
            await foreach (var result in operation.GetValuesAsync())
            {
                entities.AddRange(result.Entities);
            }
            
            return entities;
        }

        private async Task<IntentionClassification> ClassifyIntentions(
            TranscriptionChunk chunk, 
            List<HealthcareEntity> entities)
        {
            var systemPrompt = @"
            Você é um classificador de intenções médicas. Analise a transcrição e entidades extraídas 
            para identificar as intenções clínicas presentes.

            Intenções possíveis:
            - PRESCREVER: paciente precisa de medicação
            - AGENDAR: marcar retorno ou consulta
            - LAUDAR: gerar laudo ou atestado
            - EVOLUIR: documentar evolução clínica
            - ENCAMINHAR: referenciar para especialista

            Retorne JSON com confidence score (0-1) para cada intenção detectada.
            ";

            var userPrompt = $@"
            Transcrição: {chunk.Text}
            Speaker: {chunk.Speaker}
            Entidades médicas: {JsonSerializer.Serialize(entities.Select(e => new { e.Text, e.Category }))}
            
            Retorne apenas JSON válido.
            ";

            var chatRequest = new ChatCompletionsOptions
            {
                Messages = {
                    new ChatRequestSystemMessage(systemPrompt),
                    new ChatRequestUserMessage(userPrompt)
                },
                Temperature = 0.3f,
                MaxTokens = 500
            };

            var response = await _openAIClient.GetChatCompletionsAsync("gpt-4", chatRequest);
            var jsonResponse = response.Value.Choices[0].Message.Content;
            
            return JsonSerializer.Deserialize<IntentionClassification>(jsonResponse);
        }
    }

    // 2. PRESCRIPTION AGENT - Especialista em receitas
    public class PrescriptionAgent : ISpecializedAgent
    {
        private readonly OpenAIClient _openAIClient;
        private readonly string _assistantId;

        public PrescriptionAgent(OpenAIClient openAI)
        {
            _openAIClient = openAI;
            _assistantId = CreateOrGetAssistant().Result;
        }

        public bool ShouldActivate(IntentionClassification intentions, List<HealthcareEntity> entities)
        {
            return intentions.Prescrever > 0.7 || 
                   entities.Any(e => e.Category == HealthcareEntityCategory.MedicationName);
        }

        public async Task<AgentResult> ProcessAsync(
            TranscriptionChunk chunk, 
            List<HealthcareEntity> entities, 
            IntentionClassification intentions)
        {
            // Identificar medicações, dosagens e frequências
            var medications = entities.Where(e => e.Category == HealthcareEntityCategory.MedicationName);
            var dosages = entities.Where(e => e.Category == HealthcareEntityCategory.Dosage);
            var frequencies = entities.Where(e => e.Category == HealthcareEntityCategory.Frequency);

            if (medications.Any())
            {
                var prescriptionData = new
                {
                    medications = medications.Select(m => m.Text),
                    dosages = dosages.Select(d => d.Text),
                    frequencies = frequencies.Select(f => f.Text),
                    context = chunk.Text
                };

                // Gerar receita usando assistant especializado
                var thread = await _openAIClient.GetAssistantClient().CreateThreadAsync();
                
                var message = await _openAIClient.GetAssistantClient().CreateMessageAsync(
                    thread.Value.Id,
                    MessageRole.User,
                    $"Gere uma receita médica com base nos dados: {JsonSerializer.Serialize(prescriptionData)}"
                );

                var run = await _openAIClient.GetAssistantClient().CreateRunAsync(
                    thread.Value.Id,
                    _assistantId
                );

                // Aguardar conclusão e obter resultado
                while (run.Value.Status == RunStatus.InProgress || run.Value.Status == RunStatus.Queued)
                {
                    await Task.Delay(1000);
                    run = await _openAIClient.GetAssistantClient().GetRunAsync(thread.Value.Id, run.Value.Id);
                }

                var messages = await _openAIClient.GetAssistantClient().GetMessagesAsync(thread.Value.Id);
                var prescription = messages.Value.Data.First().Content.First().Text;

                return new AgentResult
                {
                    Documents = new List<GeneratedDocument>
                    {
                        new GeneratedDocument
                        {
                            Type = "Receita Médica",
                            Content = prescription,
                            Template = "templates/receita_medica.md",
                            Metadata = new { medications, dosages, frequencies }
                        }
                    },
                    Actions = new List<string> { "Receita gerada automaticamente" },
                    Confidence = intentions.Prescrever
                };
            }

            return new AgentResult { Confidence = 0 };
        }

        private async Task<string> CreateOrGetAssistant()
        {
            var tools = new List<ToolDefinition>
            {
                new FunctionToolDefinition
                {
                    Function = new FunctionDefinition
                    {
                        Name = "validate_medication_interaction",
                        Description = "Valida interações medicamentosas",
                        Parameters = BinaryData.FromObjectAsJson(new
                        {
                            type = "object",
                            properties = new
                            {
                                medications = new { type = "array", items = new { type = "string" } }
                            }
                        })
                    }
                }
            };

            var assistant = await _openAIClient.GetAssistantClient().CreateAssistantAsync(
                "gpt-4",
                new AssistantCreationOptions
                {
                    Name = "Prescription Specialist",
                    Instructions = @"
                    Você é um especialista em prescrições médicas. Sua função é:
                    1. Analisar medicações mencionadas na transcrição
                    2. Estruturar receitas médicas seguindo padrões brasileiros
                    3. Validar dosagens e frequências
                    4. Alertar sobre possíveis interações
                    5. Gerar documentos em formato apropriado para impressão

                    Sempre mantenha precisão técnica e siga protocolos médicos.
                    ",
                    Tools = tools
                }
            );

            return assistant.Value.Id;
        }
    }

    // 3. APPOINTMENT AGENT - Especialista em agendamentos
    public class AppointmentAgent : ISpecializedAgent
    {
        private readonly OpenAIClient _openAIClient;
        private readonly GraphServiceClient _graphClient;
        private readonly string _assistantId;

        public AppointmentAgent(OpenAIClient openAI, GraphServiceClient graphClient = null)
        {
            _openAIClient = openAI;
            _graphClient = graphClient;
            _assistantId = CreateOrGetAssistant().Result;
        }

        public bool ShouldActivate(IntentionClassification intentions, List<HealthcareEntity> entities)
        {
            return intentions.Agendar > 0.6 ||
                   entities.Any(e => e.Text.Contains("retorno") || 
                                     e.Text.Contains("próxima") || 
                                     e.Text.Contains("agendar"));
        }

        public async Task<AgentResult> ProcessAsync(
            TranscriptionChunk chunk, 
            List<HealthcareEntity> entities, 
            IntentionClassification intentions)
        {
            // Extrair informações temporais
            var temporalInfo = ExtractTemporalInformation(chunk.Text);
            
            if (temporalInfo.HasValidSchedulingIntent)
            {
                // Criar agendamento via Microsoft Graph
                var newEvent = new Event
                {
                    Subject = $"Retorno - {chunk.PatientName ?? "Paciente"}",
                    Start = new DateTimeTimeZone
                    {
                        DateTime = temporalInfo.ProposedDateTime.ToString("yyyy-MM-ddTHH:mm:ss.0000000"),
                        TimeZone = "America/Sao_Paulo"
                    },
                    End = new DateTimeTimeZone
                    {
                        DateTime = temporalInfo.ProposedDateTime.AddMinutes(30).ToString("yyyy-MM-ddTHH:mm:ss.0000000"),
                        TimeZone = "America/Sao_Paulo"
                    },
                    Body = new ItemBody
                    {
                        ContentType = BodyType.Text,
                        Content = $"Agendamento automático baseado na consulta. Contexto: {chunk.Text.Substring(0, Math.Min(200, chunk.Text.Length))}..."
                    }
                };

                if (_graphClient != null)
                {
                    try
                    {
                        var createdEvent = await _graphClient.Me.Calendar.Events.PostAsync(newEvent);
                        
                        return new AgentResult
                        {
                            Actions = new List<string> 
                            { 
                                $"Retorno agendado para {temporalInfo.ProposedDateTime:dd/MM/yyyy HH:mm}",
                                $"Event ID: {createdEvent.Id}"
                            },
                            Documents = new List<GeneratedDocument>(),
                            Confidence = intentions.Agendar
                        };
                    }
                    catch (Exception ex)
                    {
                        return new AgentResult
                        {
                            Actions = new List<string> { $"Erro ao agendar: {ex.Message}" },
                            Confidence = 0
                        };
                    }
                }
                else
                {
                    return new AgentResult
                    {
                        Actions = new List<string> 
                        { 
                            $"Agendamento identificado para {temporalInfo.ProposedDateTime:dd/MM/yyyy HH:mm} (Graph não configurado)"
                        },
                        Confidence = intentions.Agendar
                    };
                }
            }

            return new AgentResult { Confidence = 0 };
        }

        private TemporalInformation ExtractTemporalInformation(string text)
        {
            // Lógica para extrair datas/horários do texto
            // Exemplo: "retorno em 15 dias", "próxima semana", "mês que vem"
            
            var now = DateTime.Now;
            var info = new TemporalInformation();

            if (text.Contains("15 dias") || text.Contains("quinze dias"))
            {
                info.ProposedDateTime = now.AddDays(15);
                info.HasValidSchedulingIntent = true;
            }
            else if (text.Contains("próxima semana"))
            {
                info.ProposedDateTime = now.AddDays(7);
                info.HasValidSchedulingIntent = true;
            }
            else if (text.Contains("mês") && text.Contains("próximo"))
            {
                info.ProposedDateTime = now.AddMonths(1);
                info.HasValidSchedulingIntent = true;
            }

            // Ajustar para horário comercial (9h-17h)
            if (info.HasValidSchedulingIntent)
            {
                var hour = info.ProposedDateTime.Hour;
                if (hour < 9) info.ProposedDateTime = info.ProposedDateTime.Date.AddHours(9);
                if (hour > 17) info.ProposedDateTime = info.ProposedDateTime.Date.AddDays(1).AddHours(9);
            }

            return info;
        }

        private async Task<string> CreateOrGetAssistant()
        {
            var tools = new List<ToolDefinition>
            {
                new FunctionToolDefinition
                {
                    Function = new FunctionDefinition
                    {
                        Name = "find_available_slots",
                        Description = "Encontra horários disponíveis na agenda",
                        Parameters = BinaryData.FromObjectAsJson(new
                        {
                            type = "object",
                            properties = new
                            {
                                preferred_date = new { type = "string", format = "date" },
                                duration_minutes = new { type = "integer", @default = 30 }
                            }
                        })
                    }
                }
            };

            var assistant = await _openAIClient.GetAssistantClient().CreateAssistantAsync(
                "gpt-4",
                new AssistantCreationOptions
                {
                    Name = "Appointment Scheduler",
                    Instructions = @"
                    Você é um especialista em agendamentos médicos. Suas funções:
                    1. Identificar intenções de agendamento na transcrição
                    2. Extrair informações temporais (datas, períodos)
                    3. Propor horários adequados
                    4. Integrar com calendário via Microsoft Graph
                    5. Confirmar agendamentos automaticamente

                    Considere horário comercial (9h-17h) e evite fins de semana.
                    ",
                    Tools = tools
                }
            );

            return assistant.Value.Id;
        }
    }

    // 4. INTERFACES E MODELOS DE DADOS
    public interface ISpecializedAgent
    {
        bool ShouldActivate(IntentionClassification intentions, List<HealthcareEntity> entities);
        Task<AgentResult> ProcessAsync(TranscriptionChunk chunk, List<HealthcareEntity> entities, IntentionClassification intentions);
    }

    public class TranscriptionChunk
    {
        public string Text { get; set; }
        public string Speaker { get; set; } // speaker_0, speaker_1
        public DateTime Timestamp { get; set; }
        public string PatientName { get; set; }
        public double Confidence { get; set; }
    }

    public class IntentionClassification
    {
        public double Prescrever { get; set; }
        public double Agendar { get; set; }
        public double Laudar { get; set; }
        public double Evoluir { get; set; }
        public double Encaminhar { get; set; }
    }

    public class AgentResult
    {
        public List<GeneratedDocument> Documents { get; set; } = new();
        public List<string> Actions { get; set; } = new();
        public double Confidence { get; set; }
    }

    public class AgentResponse
    {
        public List<string> TriggeredAgents { get; set; } = new();
        public List<GeneratedDocument> GeneratedDocuments { get; set; } = new();
        public List<string> Actions { get; set; } = new();
        public double ConfidenceScore { get; set; }
        public string Message { get; set; }
    }

    public class GeneratedDocument
    {
        public string Type { get; set; }
        public string Content { get; set; }
        public string Template { get; set; }
        public object Metadata { get; set; }
        public DateTime GeneratedAt { get; set; } = DateTime.Now;
    }

    public class TemporalInformation
    {
        public DateTime ProposedDateTime { get; set; }
        public bool HasValidSchedulingIntent { get; set; }
        public string OriginalText { get; set; }
    }
}