# MCP example

To add your component (resource, promt, tool) just go to `src/mcp_server_wrapper.js` and add it to the init

```javascript
 async init() {
   await this.addComponent(new CensusUsMCP());
   //Add here yout component
}
```

you can change the name of the MCP and the version in `src/mcp_server_wrapper.js` changing the values of the constants
```javascript
export const MCP_NAME="census";
export const MCP_VERSION="1.0.0";
```


## Testing locally

you can use `npx @modelcontextprotocol/inspector node index_cmd.js` to test your component locally. 

If you want to use sse, you can use `npx @modelcontextprotocol/inspector node index.js` to test your component locally. In the inspector you need to configure to use `sse` at endpoint `http://127.0.0.1:8080/sse` 

also If you want to test it locally with `calude.ai`

Edit `~/Library/Application\ Support/Claude/claude_desktop_config.json`
and add

```json
{
    "mcpServers": {
        "<mcp name>": {
            "command": "node",
            "args": [
                "<project directory>/index_cmd.js"
            ]
        }
    }
}
```


