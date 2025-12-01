connected_websockets = set()

async def broadcast(message: dict):
    dead = []
    for ws in connected_websockets:
        try:
            await ws.send_json(message)
        except:
            dead.append(ws)

    for ws in dead:
        connected_websockets.remove(ws)