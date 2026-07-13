import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

import CensusUsMCP from "./census_us_mcp.js";

export const MCP_NAME="census";
export const MCP_VERSION="1.0.0";
export class MPCServerWrapper {
    constructor() {
        this.server = new McpServer({
            name: MCP_NAME,
            version: MCP_VERSION,
        });
    }

    /**
     * Add all components on init
     * @returns {Promise<void>}
     */
    async init() {
        await this.addComponent(new CensusUsMCP());
    }

    /**
     * Register a new component (tool, prompt, resource) on the server
     * @param component
     * @returns {Promise<void>}
     */
    async addComponent(component) {
        await component.registerOnServer({mcpServer: this.server});
    }

    getServer() {
        return this.server;
    }

}
