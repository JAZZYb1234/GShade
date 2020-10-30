#include "ReShade.fxh"
/*
ReVeil for Reshade
By: Lord of Lunacy


This shader attempts to remove fog using a dark channel prior technique that has been
refined using 2 passes over an iterative guided Wiener filter ran on the image dark channel.

The purpose of the Wiener filters is to minimize the root mean square error between
the given dark channel, and the true dark channel, making the removal more accurate.

The airlight of the image is estimated by using the max values that appears in the each
window of the dark channel. This window is then averaged together with every mip level
that is larger than the current window size.

Koschmeider's airlight equation is then used to remove the veil from the image, and the inverse
is applied to reverse this affect, blending any new image components with the fog.


This method was adapted from the following paper:
Gibson, Kristofor & Nguyen, Truong. (2013). Fast single image fog removal using the adaptive Wiener filter.
2013 IEEE International Conference on Image Processing, ICIP 2013 - Proceedings. 714-718. 10.1109/ICIP.2013.6738147. 
*/

#define CONST_LOG2(x) (\
    (uint((x) & 0xAAAAAAAA) != 0) | \
    (uint(((x) & 0xFFFF0000) != 0) << 4) | \
    (uint(((x) & 0xFF00FF00) != 0) << 3) | \
    (uint(((x) & 0xF0F0F0F0) != 0) << 2) | \
    (uint(((x) & 0xCCCCCCCC) != 0) << 1))
	
#define BIT2_LOG2(x) ( (x) | (x) >> 1)
#define BIT4_LOG2(x) ( BIT2_LOG2(x) | BIT2_LOG2(x) >> 2)
#define BIT8_LOG2(x) ( BIT4_LOG2(x) | BIT4_LOG2(x) >> 4)
#define BIT16_LOG2(x) ( BIT8_LOG2(x) | BIT8_LOG2(x) >> 8)

#define FOGREMOVAL_LOG2(x) (CONST_LOG2( (BIT16_LOG2(x) >> 1) + 1))
	    
	

#define FOGREMOVAL_MAX(a, b) (int((a) > (b)) * (a) + int((b) > (a)) * (b))

#define FOGREMOVAL_GET_MAX_MIP(w, h) \
(FOGREMOVAL_LOG2((FOGREMOVAL_MAX((w), (h))) + 1))

#define MAX_MIP (FOGREMOVAL_GET_MAX_MIP(BUFFER_WIDTH * 2 - 1, BUFFER_HEIGHT * 2 - 1))

#define REVEIL_WINDOW_SIZE 16
#define REVEIL_WINDOW_SIZE_SQUARED 256
#define RENDERER __RENDERER__

#if (((RENDERER >= 0xb000 && RENDERER < 0x10000) || (RENDERER >= 0x14300)) && __RESHADE__ >40800)
	#ifndef REVEIL_COMPUTE
	#define REVEIL_COMPUTE 1
	#endif
#else
#define REVEIL_COMPUTE 0
#endif

uniform float TransmissionMultiplier<
	ui_type = "slider";
	ui_label = "Strength";
	ui_tooltip = "The overall strength of the removal, negative values correspond to more removal,\n"
				"and positive values correspond to less.";
	ui_min = -1; ui_max = 1;
	ui_step = 0.001;
> = -0.125;

uniform float DepthMultiplier<
	ui_type = "slider";
	ui_label = "Depth Sensitivity";
	ui_tooltip = "This setting is for adjusting how much of the removal is depth based, or if\n"
				"positive values are set, it will actually add fog to the scene. 0 means it is\n"
				"unaffected by depth.";
	ui_min = -1; ui_max = 1;
	ui_step = 0.001;
> = -0.075;
texture Transmission {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16f;};
namespace ReVeilCS
{
texture BackBuffer : COLOR;
texture Mean <Pooled = true;> {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16f;};
texture Variance <Pooled = true;> {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16f; MipLevels = MAX_MIP;};
texture Airlight {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16f;};
texture OriginalImage {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGB10A2;};

#if REVEIL_COMPUTE == 1
texture Maximum <Pooled = true;> {Width = ((BUFFER_WIDTH - 1) / 16) + 1; Height = ((BUFFER_HEIGHT - 1) / 16) + 1; Format = R8; MipLevels = MAX_MIP - 4;};
#else
texture MeanAndVariance <Pooled = true;> {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RG16f;};
texture Maximum0 <Pooled = true;> {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};
texture Maximum <Pooled = true;> {Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R8;};

sampler sMeanAndVariance {Texture = MeanAndVariance;};
sampler sMaximum0 {Texture = Maximum0;};
#endif

sampler sBackBuffer {Texture = BackBuffer;};
sampler sMean {Texture = Mean;};
sampler sVariance {Texture = Variance;};
sampler sMaximum {Texture = Maximum;};
sampler sTransmission {Texture = Transmission;};
sampler sAirlight {Texture = Airlight;};
sampler sOriginalImage {Texture = OriginalImage;};

#if REVEIL_COMPUTE == 1
storage wMean {Texture = Mean;};
storage wVariance {Texture = Variance;};
storage wMaximum {Texture = Maximum;};
storage wTransmission {Texture = Transmission;};
storage wAirlight {Texture = Airlight;};
storage wOriginalImage {Texture = OriginalImage;};

groupshared float2 prefixSums[1024];
groupshared uint maximum;
void MeanAndVarianceCS(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID)
{
	uint2 groupCoord = id.xy - tid.xy;
	if(tid.x == 0)
	{
		maximum = 0;
	}
	barrier();
	
	//Indexing locations for the shader
	uint index[5];
	int x[4] = {int(tid.x), int(tid.x + 16), int(tid.x), int(tid.x + 16)};
	int y[4] = {int(tid.y), int(tid.y), int(tid.y + 16), int(tid.y + 16)};
	index[0] = y[0] * 32 + x[0];
	index[1] = y[1] * 32 + x[1];
	index[2] = y[2] * 32 + x[2];
	index[3] = y[3] * 32 + x[3];
	index[4] = index[0] + 264;
	int a[4] = {int(int(tid.x) - 8), int(int(tid.x) + 8), int(int(tid.x) - 8), int(int(tid.x) + 8)};
	int b[4] = {int(int(tid.y) - 8), int(int(tid.y) - 8), int(int(tid.y) + 8), int(int(tid.y) + 8)};
	/**/
	float3 originalImage;
	float2 sum[4];
	[unroll]
	for(int i = 0; i < 4; i++)
	{
		int2 coord = groupCoord + int2(a[i], b[i]);
		float3 color = tex2Dfetch(sBackBuffer, coord).rgb;
		float minimum = min(min(color.r, color.b), color.g);
		sum[i] = float2(minimum, minimum * minimum);
		prefixSums[index[i]] = sum[i];
		if(i == 0)
		{
			atomicMax(maximum, uint((prefixSums[index[i]].r) * 255));
		}
	}
	barrier();

	if(all(tid==0))
	{
		uint2 coord = id.xy / 16;
		tex2Dstore(wMaximum, coord, float4((float(maximum) * 1) / 255, 0, 0, 0));
	}
	
	//Generating rows of summed area table
	[unroll]
	for(int j = 0; j < 5; j++)
	{
		
		[unroll]
		for(int i = 0; i < 4; i++)
		{
			int address = index[i];
			
			int access = x[i] - exp2(j);
			access += y[i] * 32;
			if(x[i] >= exp2(j))
			{
			sum[i] += prefixSums[access];
			}
		}
		groupMemoryBarrier();
		[unroll]
		for(int i = 0; i < 4; i++)
		{
			int address = index[i];
			prefixSums[address] = sum[i];
		}
		barrier();
	}
	
	//Generating columns of summed area table
	[unroll]
	for(int j = 0; j < 5; j++)
	{

		[unroll]
		for(int i = 0; i < 4; i++)
		{
			int address = index[i];
			
			int access = y[i] - exp2(j);
			access *= 32;
			access += x[i];
			if(y[i] >= exp2(j))
			{
			sum[i] += prefixSums[access];
			}
		}
		groupMemoryBarrier();
		[unroll]
		for(int i = 0; i < 4; i++)
		{
			int address = index[i];
			prefixSums[address] = sum[i];
		}
		barrier();
	}

	//sampling from summed area table, and extractions the desired values
	float2 sums = sum[3] - sum[2] - sum[1] + sum[0];
	float mean = sums.x / 256;
	float variance = ((sums.y) - ((sums.x * sums.x) / 256));
	variance /= 256;
	

	
	tex2Dstore(wMean, id.xy, float4(mean, 0, 0, 0));
	tex2Dstore(wVariance, id.xy, float4(variance, 0, 0, 0));
}

void WienerFilterCS(uint3 id : SV_DispatchThreadID, uint3 tid : SV_GroupThreadID)
{
	float2 texcoord = id.xy / float2(BUFFER_WIDTH, BUFFER_HEIGHT);
	float mean = tex2Dfetch(sMean, id.xy).r;
	float variance = tex2Dfetch(sVariance, id.xy).r;
	float noise = tex2Dlod(sVariance, float4(texcoord, 0, MAX_MIP - 1)).r;
	float3 color = tex2Dfetch(sBackBuffer, id.xy).rgb;
	float darkChannel = min(min(color.r, color.g), color.b);
	float maximum = 0;
	
	tex2Dstore(wOriginalImage, id.xy, float4(color, 1));
	
	[unroll]
	for(int i = 0; i < MAX_MIP - 4; i++)
	{
		maximum += tex2Dlod(sMaximum, float4(texcoord, 0, i)).r;
	}
	maximum /= MAX_MIP - 5;	
	
	float filter = saturate((max((variance - noise), 0) / variance) * (darkChannel - mean));
	float veil = saturate(mean + filter);
	//filter = ((variance - noise) / variance) * (darkChannel - mean);
	//mean += filter;
	float usedVariance = variance;
	
	float airlight = clamp(maximum, 0.05, 1);//max(saturate(mean + sqrt(usedVariance) * StandardDeviations), 0.05);
	tex2Dstore(wAirlight, id.xy, float4(airlight, 0, 0, 0));
	float transmission = (1 - ((veil * darkChannel) / airlight));
	transmission *= (exp(DepthMultiplier * ReShade::GetLinearizedDepth(texcoord)));
	transmission *= exp(TransmissionMultiplier);
	tex2Dstore(wTransmission, id.xy, float4(transmission, 0, 0, 0));
}

void WienerFilterPS(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float transmission : SV_TARGET0, out float airlight : SV_TARGET1, out float4 originalImage : SV_TARGET2)
{
	float mean = tex2D(sMean, texcoord).r;
	float variance = tex2D(sVariance, texcoord).r;
	float noise = tex2Dlod(sVariance, float4(texcoord, 0, MAX_MIP - 1)).r;
	float3 color = tex2D(sBackBuffer, texcoord).rgb;
	float darkChannel = min(min(color.r, color.g), color.b);
	float maximum = 0;
	
	[unroll]
	for(int i = 1; i < MAX_MIP - 4; i++)
	{
		maximum += tex2Dlod(sMaximum, float4(texcoord, 0, i)).r;
	}
	maximum /= MAX_MIP - 5;	
	
	float filter = saturate((max((variance - noise), 0) / variance) * (darkChannel - mean));
	float veil = saturate(mean + filter);
	//filter = ((variance - noise) / variance) * (darkChannel - mean);
	//mean += filter;
	float usedVariance = variance;
	
	airlight = clamp(maximum, 0.05, 1);//max(saturate(mean + sqrt(usedVariance) * StandardDeviations), 0.05);
	transmission = (1 - ((veil * darkChannel) / airlight));
	transmission *= (exp(DepthMultiplier * ReShade::GetLinearizedDepth(texcoord)));
	transmission *= exp(TransmissionMultiplier);

     originalImage = float4(color, 1);   

}
#else

void MeanAndVariancePS0(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float2 meanAndVariance : SV_TARGET0, out float maximum : SV_TARGET1)
{
	float darkChannel;
	float sum = 0;
	float squaredSum = 0;
	maximum = 0;
	for(int i = -(REVEIL_WINDOW_SIZE / 2); i < ((REVEIL_WINDOW_SIZE + 1) / 2); i++)
	{
			float2 offset = float2(i * BUFFER_RCP_WIDTH, 0);
			float3 color = tex2D(sBackBuffer, texcoord + offset).rgb;
			darkChannel = min(min(color.r, color.g), color.b);
			float darkChannelSquared = darkChannel * darkChannel;
			float darkChannelCubed = darkChannelSquared * darkChannel;
			sum += darkChannel;
			squaredSum += darkChannelSquared;
			maximum = max(maximum, darkChannel);
			
	}
	meanAndVariance = float2(sum, squaredSum);
}


void MeanAndVariancePS1(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float mean : SV_TARGET0, out float variance : SV_TARGET1, out float maximum : SV_TARGET2)
{
	float2 meanAndVariance;
	float sum = 0;
	float squaredSum = 0;
	maximum = 0;
	for(int i = -(REVEIL_WINDOW_SIZE / 2); i < ((REVEIL_WINDOW_SIZE + 1) / 2); i++)
	{
			float2 offset = float2(0, i * BUFFER_RCP_HEIGHT);
			meanAndVariance = tex2D(sMeanAndVariance, texcoord + offset).rg;
			sum += meanAndVariance.r;
			squaredSum += meanAndVariance.g;
			maximum = max(maximum, tex2D(sMaximum0, texcoord + offset).r);
	}
	float sumSquared = sum * sum;
	
	mean = sum / REVEIL_WINDOW_SIZE_SQUARED;
	variance = (squaredSum - ((sumSquared) / REVEIL_WINDOW_SIZE_SQUARED));
	variance /= REVEIL_WINDOW_SIZE_SQUARED;
}

void WienerFilterPS(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float transmission : SV_TARGET0, out float airlight : SV_TARGET1, out float4 originalImage : SV_TARGET2)
{
	float mean = tex2D(sMean, texcoord).r;
	float variance = tex2D(sVariance, texcoord).r;
	float noise = tex2Dlod(sVariance, float4(texcoord, 0, MAX_MIP - 1)).r;
	float3 color = tex2D(sBackBuffer, texcoord).rgb;
	float darkChannel = min(min(color.r, color.g), color.b);
	float maximum = 0;
	
	[unroll]
	for(int i = 4; i < MAX_MIP; i++)
	{
		maximum += tex2Dlod(sMaximum, float4(texcoord, 0, i)).r;
	}
	maximum /= MAX_MIP - 4;	
	
	float filter = saturate((max((variance - noise), 0) / variance) * (darkChannel - mean));
	float veil = saturate(mean + filter);
	//filter = ((variance - noise) / variance) * (darkChannel - mean);
	//mean += filter;
	float usedVariance = variance;
	
	airlight = clamp(maximum, 0.05, 1);//max(saturate(mean + sqrt(usedVariance) * StandardDeviations), 0.05);
	transmission = (1 - ((veil * darkChannel) / airlight));
	transmission *= (exp(DepthMultiplier * ReShade::GetLinearizedDepth(texcoord)));
	transmission *= exp(TransmissionMultiplier);

     originalImage = float4(color, 1);   

}
#endif


void FogReintroductionPS(float4 vpos : SV_POSITION, float2 texcoord : TEXCOORD, out float4 fogReintroduced : SV_TARGET0)
{
	float airlight = tex2D(sAirlight, texcoord).r;
	float transmission = max((tex2D(sTransmission, texcoord).r), 0.05);
	float3 newImage = (tex2D(sBackBuffer, texcoord).rgb);
	float3 originalImage = tex2D(sOriginalImage, texcoord).rgb;
	
	float y = dot(originalImage, float3(0.299, 0.587, 0.114));
	float originalLuma = ((y - airlight) / transmission) + airlight;
	
	y = dot(newImage, float3(0.299, 0.587, 0.114));
	float newLuma = ((y - airlight) / max(transmission, 0.05)) + airlight;
	
	float blended = (originalLuma - newLuma) * (1 - transmission);
	blended += newLuma;
	blended = lerp(originalLuma, newLuma, max(transmission, 0.05));
	
	blended = ((blended - airlight) * max(transmission, 0.05)) + airlight;
	
	float cb = -0.168736 * newImage.r - 0.331264 * newImage.g + 0.500000 * newImage.b;
	float cr = +0.500000 * newImage.r - 0.418688 * newImage.g - 0.081312 * newImage.b;
    newImage = float3(
        blended + 1.402 * cr,
        blended - 0.344136 * cb - 0.714136 * cr,
        blended + 1.772 * cb);
		
	fogReintroduced = float4(newImage, 1);
	
	
	

	/*i += tex2D(sTruncatedPrecision, texcoord).rgb;
	
	float y = dot(i, float3(0.299, 0.587, 0.114));
	float3 color;
	if(tex2D(sBackBuffer, texcoord).a == 1)
	{
		//i = fogRemoved;
		y = ((y - airlight) * transmission) + airlight;

	
	float cb = -0.168736 * i.r - 0.331264 * i.g + 0.500000 * i.b;
	float cr = +0.500000 * i.r - 0.418688 * i.g - 0.081312 * i.b;
    color = float3(
        y + 1.402 * cr,
        y - 0.344136 * cb - 0.714136 * cr,
        y + 1.772 * cb);
	}
	else color = i;
		
		
	float alpha = 1;
	fogReintroduced = float4(color, 1);*/
	
}



technique ReVeil_Top <ui_tooltip = "This goes above any shaders you want to apply ReVeil to. \n\n"
								  "(Don't worry if it looks like its doing nothing, what its doing here won't take effect until ReVeil_Bottom is applied)";>
{
#if REVEIL_COMPUTE == 1
	pass MeanAndVariance
	{
		ComputeShader = MeanAndVarianceCS<16, 16>;
		DispatchSizeX = ((BUFFER_WIDTH - 1) / 16) + 1;
		DispatchSizeY = ((BUFFER_HEIGHT - 1) / 16) + 1;
	}
#else
	pass MeanAndVariance
	{
		VertexShader = PostProcessVS;
		PixelShader = MeanAndVariancePS0;
		RenderTarget0 = MeanAndVariance;
		RenderTarget1 = Maximum0;
	}
	
	pass MeanAndVariance
	{
		VertexShader = PostProcessVS;
		PixelShader = MeanAndVariancePS1;
		RenderTarget0 = Mean;
		RenderTarget1 = Variance;
		RenderTarget2 = Maximum;
	}
#endif

	
	pass WienerFilter
	{
		VertexShader = PostProcessVS;
		PixelShader = WienerFilterPS;
		RenderTarget0 = Transmission;
		RenderTarget1 = Airlight;
		RenderTarget2 = OriginalImage;
	}
}

technique ReVeil_Bottom <ui_tooptip = "This goes beneath the shaders you want to apply ReVeil to.";>
{
	pass FogReintroduction
	{
		VertexShader = PostProcessVS;
		PixelShader = FogReintroductionPS;
	}
}
}
