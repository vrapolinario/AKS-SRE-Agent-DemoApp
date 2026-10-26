FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /source
COPY src/DemoWeb/DemoWeb.csproj src/DemoWeb/
RUN dotnet restore src/DemoWeb/DemoWeb.csproj
COPY src/DemoWeb/ src/DemoWeb/
RUN dotnet publish src/DemoWeb/DemoWeb.csproj -c Release -o /app --no-restore /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
COPY --from=build /app .
ENV ASPNETCORE_HTTP_PORTS=8080
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "DemoWeb.dll"]
