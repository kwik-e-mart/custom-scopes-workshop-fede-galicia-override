import express from "express";
import { SSEServerTransport } from "@modelcontextprotocol/sdk/server/sse.js";
import {MPCServerWrapper} from "./src/mcp_server_wrapper.js";
const HOST = process.env.HOST || '0.0.0.0'
const PORT = process.env.PORT || 8080;
import { v4 as uuidv4 } from 'uuid';
const app = express();
let transport;
// Declare a route
const wrapper = new MPCServerWrapper()
await wrapper.init();

const clientTransports = new Map();

app.use((req, res, next) => {
    res.header('Access-Control-Allow-Origin', '*');
    res.header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.header('Access-Control-Allow-Headers', 'Origin, X-Requested-With, Content-Type, Accept');

    // Handle preflight requests
    if (req.method === 'OPTIONS') {
        return res.status(200).end();
    }
    next();
});
app.get("/sse", async (req, res) => {
    const newTransport = new SSEServerTransport("/messages", res);
    clientTransports.set(newTransport.sessionId, newTransport);
    const clientId = newTransport.sessionId;
    console.log(`SSE connection established for client: ${newTransport.sessionId}`);
    await wrapper.getServer().connect(newTransport);

    // Clean up when connection closes
    req.on('close', () => {
        console.log(`Client ${clientId} disconnected`);
        clientTransports.delete(clientId);
    });
});

app.post("/messages", async (req, res) => {
    const clientId = req.query.clientId || req.query.sessionId;
    if (!clientId || !clientTransports.has(clientId)) {
        console.log(clientId);
        console.log(JSON.stringify(req.query))
        console.log(JSON.stringify(req.body))
        return res.status(400).json({
            error: "No active SSE connection found for this client"
        });
    }

    await clientTransports.get(clientId).handlePostMessage(req, res);
});
app.get('/health', async (req, res) => {
    res.json({ status: 'ok' });
})

// Run the server!
const start = async () => {
    try {
        console.log("Starting");
        await app.listen(PORT, HOST);
    } catch (err) {
        console.error(err);
        process.exit(1);
    }
}
start();
