---@meta

---@class PimModel
---@field id string|nil
---@field provider string|nil
---@field name string|nil
---@field contextWindow number|nil

---@class PimApplicationState : PimBusyState
---@field connected boolean|nil
---@field model PimModel|nil
---@field thinking_level string|nil
---@field session_id string|nil
---@field session_name string|nil
---@field session_file string|nil
---@field context_tokens number|nil
---@field context_window number|nil
---@field context_percent number|nil
---@field ext_status table<string, string>
---@field ext_widgets table<string, string[]>|nil
---@field exit_code integer|nil
---@field stopped boolean|nil
---@field spawn_error string|nil
---@field config_dir string|nil

---@class PimBusyState
---@field run_active boolean|nil
---@field is_streaming boolean|nil
---@field is_compacting boolean|nil
---@field bash_running boolean|nil
---@field retrying boolean|nil

---@class PimContentBlock
---@field type string
---@field text string|nil
---@field thinking string|nil
---@field redacted boolean|nil
---@field mimeType string|nil
---@field data string|nil
---@field id string|nil
---@field name string|nil
---@field arguments table|nil

---@alias PimMessageContent string|PimContentBlock[]

---@class PimMessage
---@field role string
---@field content PimMessageContent|nil
---@field stopReason string|nil
---@field errorMessage string|nil
---@field usage table|nil
---@field toolCallId string|nil
---@field toolName string|nil
---@field isError boolean|nil
---@field details table|nil
---@field command string|nil
---@field output string|nil
---@field running boolean|nil
---@field cancelled boolean|nil
---@field failed boolean|nil
---@field exitCode integer|nil
---@field excludeFromContext boolean|nil
---@field truncated boolean|nil
---@field display boolean|nil
---@field customType string|nil
---@field summary string|nil
---@field tokensBefore number|nil

---@class PimToolResult
---@field [string] any
---@field content PimMessageContent|nil
---@field output string|nil
---@field text string|nil
---@field details table|nil

---@class PimToolExecution
---@field toolName string
---@field args table|nil
---@field preview string|nil
---@field running boolean|nil
---@field isError boolean|nil
---@field result PimToolResult|string|nil

---@class PimEvent
---@field type string|nil
---@field message PimMessage|nil
---@field assistantMessageEvent table|nil
---@field usage table|nil
---@field toolCallId string|nil
---@field toolName string|nil
---@field args table|nil
---@field partialResult PimToolResult|string|nil
---@field result PimToolResult|string|nil
---@field isError boolean|nil
---@field steering string[]|nil
---@field followUp string[]|nil
---@field willRetry boolean|nil
---@field name string|nil
---@field level string|nil

---@class PimRpcState
---@field [string] any
---@field isStreaming boolean|nil
---@field isCompacting boolean|nil
---@field model PimModel|nil
---@field thinkingLevel string|nil
---@field sessionId string|nil
---@field sessionName string|nil
---@field sessionFile string|nil

---@class PimRpcMessagesResponse
---@field messages PimMessage[]

---@class PimRpcResponse
---@field type "response"
---@field id string|nil
---@field command string|nil
---@field success boolean
---@field data any
---@field error any

---@class PimRpcSessionActionResponse
---@field cancelled boolean

---@class PimRpcForkResponse : PimRpcSessionActionResponse
---@field text string

---@class PimRpcContextUsage
---@field tokens number
---@field contextWindow number
---@field percent number

---@class PimRpcSessionStats
---@field contextUsage PimRpcContextUsage|nil
---@field sessionFile string|nil

---@class PimRpcQueueResponse
---@field steering string[]
---@field followUp string[]

---@class PimRpcForkMessage
---@field entryId string
---@field text string

---@class PimRpcForkMessagesResponse
---@field messages PimRpcForkMessage[]

---@class PimRpcTreeResponse
---@field tree PimSessionTreeNode[]
---@field leafId string|nil

---@class PimSessionInfo
---@field id string
---@field timestamp string
---@field cwd string
---@field name string|nil
---@field preview string|nil
---@field message_count integer
---@field path string|nil
---@field mtime integer|nil

---@class PimSessionEntry
---@field type string
---@field id string|nil
---@field message PimMessage|nil
---@field provider string|nil
---@field modelId string|nil
---@field thinkingLevel string|nil
---@field summary string|nil
---@field tokensBefore number|nil
---@field customType string|nil
---@field content PimMessageContent|nil
---@field display boolean|nil
---@field label string|nil
---@field name string|nil

---@class PimSessionTreeNode
---@field entry PimSessionEntry
---@field children PimSessionTreeNode[]|nil
---@field label string|nil

---@class PimTreeRow
---@field entry PimSessionEntry
---@field id string|nil
---@field line string

---@class PimRenderedFold
---@field first integer
---@field last integer
---@field kind "tool_calls"|"tool_results"|"thinking"|"bash_output"
---@field id string|nil

---@class PimRenderedHeader
---@field role "user"|"assistant"|"custom"
---@field row integer Zero-based header row within the block.

---@class PimRenderedBlock
---@field lines string[]
---@field folds PimRenderedFold[]
---@field header PimRenderedHeader|nil

---@class PimTranscriptBlock : PimRenderedBlock
---@field key string
---@field kind string
---@field mark integer|nil
---@field srow integer|nil
---@field final boolean

return {}
