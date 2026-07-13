import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {MCP_NAME, MPCServerWrapper} from "./src/mcp_server_wrapper.js";
async function main() {
    const transport = new StdioServerTransport();
    const wrapper = new MPCServerWrapper();
    await wrapper.init();

    await wrapper.getServer().connect(transport);
    console.error(`${MCP_NAME} MCP Server running on stdio`);
}

main().catch((error) => {
    console.error("Fatal error in main():", error);
    process.exit(1);
});
