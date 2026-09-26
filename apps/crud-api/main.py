import os

from fastapi import FastAPI, Depends
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker, AsyncSession
from sqlalchemy import text

# Connection settings come from the Deployment env (crud-values.yaml + crud-db Secret).
DATABASE_URL = "postgresql+asyncpg://{user}:{password}@{host}:{port}/{name}".format(
    user=os.getenv("DB_USER", "postgres"),
    password=os.environ["DB_PASSWORD"],
    host=os.getenv("DB_HOST", "postgres.data.svc.cluster.local"),
    port=os.getenv("DB_PORT", "5432"),
    name=os.getenv("DB_NAME", "crud"),
)
# pool_pre_ping: check a pooled connection before using it. Idle connections
# get closed (for example by the Istio sidecar), and without this the first
# request after a quiet spell fails with "connection is closed".
engine = create_async_engine(DATABASE_URL, pool_pre_ping=True)
AsyncSessionLocal = async_sessionmaker(engine, expire_on_commit=False)

app = FastAPI()

async def get_db():
    async with AsyncSessionLocal() as session:
        yield session

@app.get("/healthz")
async def healthz():
    return {"status": "ok"}

@app.get("/api/v1/users/{user_id}")
async def get_user_v1(user_id: int, db: AsyncSession = Depends(get_db)):
    query = text("SELECT id, standard_data FROM users_v1 WHERE id = :id")
    result = await db.execute(query, {"id": user_id})
    return dict(result.mappings().first() or {})

@app.get("/api/v2/users/{user_id}")
async def get_user_v2(user_id: int, db: AsyncSession = Depends(get_db)):
    query = text("SELECT id, experimental_data FROM users_v2 WHERE id = :id")
    result = await db.execute(query, {"id": user_id})
    return dict(result.mappings().first() or {})
