from mcp.server.mcpserver import MCPServer
from mcp.types import CallToolResult, TextContent

mcp = MCPServer("spike7")

@mcp.tool()
def plain_fail() -> str:
    """Raises: the SDK's default error path."""
    raise RuntimeError("bridge_not_alive: heartbeat age 42 s")

@mcp.tool()
def structured_fail() -> CallToolResult:
    """Returns an explicit error result that also carries structured data."""
    return CallToolResult(
        content=[TextContent(type="text", text="bridge_not_alive: heartbeat age 42 s")],
        structured_content={"kind": "bridge_not_alive", "heartbeat_age_s": 42},
        is_error=True,
    )

if __name__ == "__main__":
    mcp.run(transport="stdio")
