import asyncio, sys
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

async def main():
    params = StdioServerParameters(command=sys.executable, args=["spike7_server.py"])
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            for name in ("plain_fail", "structured_fail"):
                r = await session.call_tool(name, {})
                print(name, "| is_error:", r.is_error, "| text:", [c.text for c in r.content], "| structured:", r.structured_content)

asyncio.run(main())
