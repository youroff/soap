defmodule Soap.Wsdl do
  @moduledoc """
  Provides functions for parsing wsdl file
  """
  @soap_version_namespaces %{
    "1.1" => :"http://schemas.xmlsoap.org/wsdl/soap/",
    "1.2" => :"http://schemas.xmlsoap.org/wsdl/soap12/"
  }

  import SweetXml, except: [parse: 1, parse: 2]

  alias Soap.{Request, Type, Xsd}

  @spec parse_from_file(String.t()) :: {:ok, map()}
  def parse_from_file(path, opts \\ []) do
    {:ok, wsdl} = File.read(path)
    parse(wsdl, path, opts)
  end

  @spec parse_from_url(String.t()) :: {:ok, map()}
  def parse_from_url(path, opts \\ []) do
    request_opts = Keyword.merge([follow_redirect: true, max_redirect: 5], opts)
    %HTTPoison.Response{body: wsdl} = Request.get_http_client().get!(path, [], request_opts)
    parse(wsdl, path, opts)
  end

  @spec parse(String.t(), String.t(), map()) :: {:ok, map()}
  def parse(wsdl, file_path, opts \\ []) do
    wsdl = SweetXml.parse(wsdl)

    protocol_namespace = get_protocol_namespace(wsdl)
    soap_namespace = get_soap_namespace(wsdl, opts)
    schema_namespace = get_schema_namespace(wsdl)
    endpoint = get_endpoint(wsdl, protocol_namespace, soap_namespace)

    parsed_response = %{
      namespaces: get_namespaces(wsdl, schema_namespace, protocol_namespace),
      endpoint: endpoint,
      complex_types: get_complex_types(wsdl, schema_namespace, protocol_namespace),
      operations: get_operations(wsdl, protocol_namespace, soap_namespace, opts),
      schema_attributes: get_schema_attributes(wsdl),
      validation_types: get_validation_types(wsdl, file_path, protocol_namespace, schema_namespace, endpoint),
      soap_version: soap_version(opts),
      messages: get_messages(wsdl, protocol_namespace)
    }

    {:ok, parsed_response}
  end

  @spec get_schema_namespace(String.t()) :: String.t()
  defp get_schema_namespace(wsdl) do
    {_, _, _, schema_namespace, _} =
      wsdl
      |> xpath(~x"//namespace::*"l)
      |> Enum.find(fn {_, _, _, _, x} -> x == :"http://www.w3.org/2001/XMLSchema" end)

    schema_namespace
  end

  @spec get_namespaces(String.t(), String.t(), String.t()) :: map()
  defp get_namespaces(wsdl, schema_namespace, protocol_ns) do
    wsdl
    |> xpath(~x"//#{ns("definitions", protocol_ns)}/namespace::*"l)
    |> Enum.into(%{}, &get_namespace(&1, wsdl, schema_namespace, protocol_ns))
  end

  @spec get_namespace(map(), String.t(), String.t(), String.t()) :: tuple()
  defp get_namespace(namespaces_node, wsdl, schema_namespace, protocol_ns) do
    {_, _, _, key, value} = namespaces_node
    string_key = key |> to_string
    value = Atom.to_string(value)

    cond do
      xpath(wsdl, ~x"//#{ns("definitions", protocol_ns)}[@targetNamespace='#{value}']") ->
        {string_key, %{value: value, type: :wsdl}}

      xpath(
        wsdl,
        ~x"//#{ns("types", protocol_ns)}/#{ns("schema", schema_namespace)}/#{ns("import", schema_namespace)}[@namespace='#{
          value
        }']"
      ) ->
        {string_key, %{value: value, type: :xsd}}

      true ->
        {string_key, %{value: value, type: :soap}}
    end
  end

  @spec get_endpoint(String.t(), String.t(), String.t()) :: String.t()
  def get_endpoint(wsdl, protocol_ns, soap_ns) do
    wsdl
    |> xpath(
      ~x"//#{ns("definitions", protocol_ns)}/#{ns("service", protocol_ns)}/#{ns("port", protocol_ns)}/#{
        ns("address", soap_ns)
      }/@location"s
    )
  end

  @spec get_complex_types(String.t(), String.t(), String.t()) :: list()
  defp get_complex_types(wsdl, namespace, protocol_ns) do
    xpath(
      wsdl,
      ~x"//#{ns("types", protocol_ns)}/#{ns("schema", namespace)}/#{ns("element", namespace)}"l,
      name: ~x"./@name"s,
      type: ~x"./@type"s
    )
  end

  @spec get_validation_types(String.t(), String.t(), String.t(), String.t(), String.t()) :: map()
  def get_validation_types(wsdl, file_path, protocol_ns, schema_ns, endpoint) do
    Map.merge(
      Type.get_complex_types(
        wsdl,
        "//#{ns("types", protocol_ns)}/#{ns("schema", schema_ns)}/#{ns("complexType", schema_ns)}"
      ),
      wsdl
      |> get_full_paths(file_path, protocol_ns, schema_ns, endpoint)
      |> get_imported_types
      |> Enum.reduce(%{}, &Map.merge(&2, &1))
    )
  end

  @spec get_schema_imports(String.t(), String.t(), String.t()) :: list()
  def get_schema_imports(wsdl, protocol_ns, schema_ns) do
    xpath(
      wsdl,
      ~x"//#{ns("types", protocol_ns)}/#{ns("schema", schema_ns)}/#{ns("import", schema_ns)}"l,
      schema_location: ~x"./@schemaLocation"s
    )
  end

  @spec get_full_paths(String.t(), String.t(), String.t(), String.t(), String.t()) :: list(String.t())
  defp get_full_paths(wsdl, path, protocol_ns, schema_namespace, endpoint) do
    wsdl
    |> get_schema_imports(protocol_ns, schema_namespace)
    |> Enum.map(&resolve_schema_imports(path, &1.schema_location, endpoint))
  end

  @spec resolve_schema_imports(String.t(), String.t(), String.t()) :: String.t()
  defp resolve_schema_imports(path, location, endpoint) do
    case URI.parse(location) do
      %URI{scheme: nil} ->
        case URI.parse(path) do
          %URI{scheme: nil} -> path |> Path.dirname() |> Path.join(location)
          _ -> Path.join(endpoint, location)
        end

      _ ->
        location
    end
  end

  @spec get_imported_types(list()) :: list(map())
  defp get_imported_types(xsd_paths) do
    xsd_paths
    |> Enum.map(fn xsd_path ->
      case Xsd.parse(xsd_path) do
        {:ok, xsd} -> xsd.complex_types
        _ -> %{}
      end
    end)
  end

  defp get_operations(wsdl, protocol_ns, soap_ns, opts) do
    wsdl
    |> xpath(~x"//#{ns("definitions", protocol_ns)}/#{ns("binding", protocol_ns)}/#{ns("operation", protocol_ns)}"l)
    |> Enum.map(fn node ->
      node
      |> xpath(~x".", name: ~x"./@name"s, soap_action: ~x"./#{ns("operation", soap_ns)}/@soapAction"s)
      |> Map.put(:input, get_operation_input(node, protocol_ns, soap_ns))
    end)
    |> Enum.reject(fn x -> x[:soap_action] == "" && !opts[:allow_empty_soap_actions] end)
  end

  defp get_operation_input(element, protocol_ns, soap_ns) do
    case xpath(element, ~x"./#{ns("input", protocol_ns)}/#{ns("header", soap_ns)}") do
      nil ->
        %{
          body: nil,
          header: nil
        }

      header_node ->
        %{
          body: nil,
          header: xpath(header_node, ~x".", message: ~x"./@message"s, part: ~x"./@part"s)
        }
    end
  end

  defp get_messages(wsdl, protocol_ns) do
    wsdl
    |> xpath(~x"//#{ns("definitions", protocol_ns)}/#{ns("message", protocol_ns)}"l)
    |> Enum.map(fn node ->
      node
      |> xpath(~x".", name: ~x"./@name"s)
      |> Map.put(:parts, get_message_parts(node, protocol_ns))
    end)
  end

  defp get_message_parts(element, protocol_ns) do
    xpath(element, ~x"./#{ns("part", protocol_ns)}"l, name: ~x"./@name"s, element: ~x"./@element"s)
  end

  @spec get_protocol_namespace(String.t()) :: String.t()
  defp get_protocol_namespace(wsdl) do
    wsdl
    |> xpath(~x"//namespace::*"l)
    |> Enum.find(fn {_, _, _, _, url} -> url == :"http://schemas.xmlsoap.org/wsdl/" end)
    |> elem(3)
  end

  @spec get_soap_namespace(String.t(), list()) :: String.t()
  defp get_soap_namespace(wsdl, opts) when is_list(opts) do
    version = soap_version(opts)
    namespace = @soap_version_namespaces[version]

    wsdl
    |> xpath(~x"//namespace::*"l)
    |> Enum.find(fn {_, _, _, _, url} -> url == namespace end)
    |> elem(3)
  end

  @spec get_schema_attributes(String.t()) :: map()
  defp get_schema_attributes(wsdl) do
    case xpath(wsdl, ~x"//*[local-name() = 'schema']") do
      nil ->
        %{}

      schema ->
        xpath(schema, ~x".",
          target_namespace: ~x"./@targetNamespace"s,
          element_form_default: ~x"./@elementFormDefault"s
        )
    end
  end

  defp soap_version, do: Application.fetch_env!(:soap, :globals)[:version]
  defp soap_version(opts) when is_list(opts), do: Keyword.get(opts, :soap_version, soap_version())

  defp ns(name, []), do: "#{name}"
  defp ns(name, namespace), do: "#{namespace}:#{name}"
end
