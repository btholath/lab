# syntax=docker/dockerfile:1
# Build context is the repository root (see docker-compose.yml).
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY api/ ./
RUN dotnet publish src/WealthWise.Api/WealthWise.Api.csproj -c Release -o /out

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /out ./
EXPOSE 8080
USER $APP_UID
ENTRYPOINT ["dotnet", "WealthWise.Api.dll"]
