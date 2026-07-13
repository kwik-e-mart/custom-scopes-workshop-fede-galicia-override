import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import axios from "axios";
export default class CensusUsMCP {

    async registerOnServer({mcpServer}) {
        mcpServer.tool("get-population",
            "Returns population for the required states, if all use *",
            {
                states: z.array(z.number().describe("State code number")).describe("List of states to query population for, use * for all")
            },
            this.getPopulationData.bind(this))
    }

    async getPopulationData({states=[]}) {
        const statesFor = states.length ? states.join(',') : '*';
        const apiUrl = "https://api.census.gov/data/2020/dec/pl";
        const params = {
            get: "NAME,P1_001N",
            for: `state:${statesFor}`,
        };

        try {
            const response = await axios.get(apiUrl, { params });
            if(response.status !== 200) {
                return {
                    content: [
                        {
                            type: "text",
                            text: `Error fetching data from Census API: ${response.status} ${response.statusText}`
                        }
                    ],
                    isError: true
                }
            }
            //Format data
            let textResponse = `Population data for states:\n`;
            for(const row of response.data) {
                textResponse += `${row[0]}\t${row[1]}\t${row[2]}\n`;
            }
            return {
                content: [
                    {
                        type: "text",
                        text: textResponse
                    }
                ]
            }
        } catch (error) {
            console.error('Error fetching data:', error);
        }
    }
}
