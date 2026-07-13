#!/bin/bash

if [[ "$NP_LOG_LEVEL" == "" ]]; then
	export NP_LOG_LEVEL="INFO"
fi

if [[ "$NP_MPC_PROTOCOL" == "backbone" ]]; then
  cat /mcp/mcp.json | envsubst > /mcp/mcp.json.replaced
  ~/.local/bin/np-agent --tags="$NP_AGENT_TAGS" \
     --apikey=$NP_API_KEY \
     --runtime=host \
     --command-executor-env="NP_API_KEY='$NP_API_KEY'" \
     --command-executor-mcp-config=/mcp/mcp.json.replaced
else
  node index.js
fi
