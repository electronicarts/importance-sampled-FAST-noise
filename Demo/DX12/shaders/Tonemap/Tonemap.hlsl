///////////////////////////////////////////////////////////////////////////////
//     Filter-Adapted Spatio-Temporal Sampling With General Distributions    //
//        Copyright (c) 2024 Electronic Arts Inc. All rights reserved.       //
///////////////////////////////////////////////////////////////////////////////

// Portions of this software are based on:
// https://github.com/TheRealMJP/BakingLab/blob/master/BakingLab/ACES.hlsl
// https://knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve/
// https://64.github.io/tonemapping/

// Tonemap technique, shader Tonemap


struct ToneMappingOperation
{
    static const int None = 0; // Only exposure is applied
    static const int Reinhard_Simple = 1; // Portions of this are based on https://64.github.io/tonemapping/
    static const int ACES_Luminance = 2; // Portions of this are based on https://knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve/
    static const int ACES = 3; // Portions of this are based on https://github.com/TheRealMJP/BakingLab/blob/master/BakingLab/ACES.hlsl
};

struct Struct__ToneMap_TonemapCB
{
    float ToneMap_ExposureFStops;
    int ToneMap_ToneMapper;
    float2 _padding0;
};

Texture2D<float4> HDR : register(t0);
RWTexture2D<float4> SDR : register(u0);
ConstantBuffer<Struct__ToneMap_TonemapCB> _ToneMap_TonemapCB : register(b0);

#line 12


float3 ACESFilm(float3 x)
{
	float a = 2.51f;
	float b = 0.03f;
	float c = 2.43f;
	float d = 0.59f;
	float e = 0.14f;
	return saturate((x*(a*x+b))/(x*(c*x+d)+e));
}

// ============= ACES BEGIN

float3 LinearToSRGB(float3 linearCol)
{
	float3 sRGBLo = linearCol * 12.92;
	float3 sRGBHi = (pow(abs(linearCol), float3(1.0 / 2.4, 1.0 / 2.4, 1.0 / 2.4)) * 1.055) - 0.055;
	float3 sRGB;
	sRGB.r = linearCol.r <= 0.0031308 ? sRGBLo.r : sRGBHi.r;
	sRGB.g = linearCol.g <= 0.0031308 ? sRGBLo.g : sRGBHi.g;
	sRGB.b = linearCol.b <= 0.0031308 ? sRGBLo.b : sRGBHi.b;
	return sRGB;
}

float3 SRGBToLinear(in float3 sRGBCol)
{
	float3 linearRGBLo = sRGBCol / 12.92;
	float3 linearRGBHi = pow((sRGBCol + 0.055) / 1.055, float3(2.4, 2.4, 2.4));
	float3 linearRGB;
	linearRGB.r = sRGBCol.r <= 0.04045 ? linearRGBLo.r : linearRGBHi.r;
	linearRGB.g = sRGBCol.g <= 0.04045 ? linearRGBLo.g : linearRGBHi.g;
	linearRGB.b = sRGBCol.b <= 0.04045 ? linearRGBLo.b : linearRGBHi.b;
	return linearRGB;
}

// sRGB => XYZ => D65_2_D60 => AP1 => RRT_SAT
static const float3x3 ACESInputMat =
{
    {0.59719, 0.35458, 0.04823},
    {0.07600, 0.90834, 0.01566},
    {0.02840, 0.13383, 0.83777}
};

// ODT_SAT => XYZ => D60_2_D65 => sRGB
static const float3x3 ACESOutputMat =
{
    { 1.60475, -0.53108, -0.07367},
    {-0.10208,  1.10813, -0.00605},
    {-0.00327, -0.07276,  1.07602}
};

float3 RRTAndODTFit(float3 v)
{
    float3 a = v * (v + 0.0245786f) - 0.000090537f;
    float3 b = v * (0.983729f * v + 0.4329510f) + 0.238081f;
    return a / b;
}

float3 ACESFitted(float3 color)
{
    color = mul(ACESInputMat, color);

    // Apply RRT and ODT
    color = RRTAndODTFit(color);

    color = mul(ACESOutputMat, color);

    // Clamp to [0, 1]
    color = saturate(color);

    return color;
}

// ============= ACES END

[numthreads(8, 8, 1)]
#line 88
void csmain(uint3 DTid : SV_DispatchThreadID)
{
	uint2 px = DTid.xy;

	// convert exposure from FStops to a multiplier
	float exposure = pow(2.0f, _ToneMap_TonemapCB.ToneMap_ExposureFStops);

	float3 rgb = max(HDR[px].rgb * exposure, 0.0f);

	switch(_ToneMap_TonemapCB.ToneMap_ToneMapper)
	{
		// Do nothing, only apply exposure
		case ToneMappingOperation::None: break;

		case ToneMappingOperation::Reinhard_Simple:
		{
			rgb = rgb / (1.0f + rgb);
			break;			
		}
		case ToneMappingOperation::ACES_Luminance:
		{
			// The * 0.6f is to undo the exposure baked in, per the author's instructions
			rgb = ACESFilm(rgb * 0.6f);
			break;
		}
		case ToneMappingOperation::ACES:
		{
			rgb = ACESFitted(rgb);
			break;
		}
	}

	rgb = clamp(rgb, 0.0f, 1.0f);
	SDR[px] = float4(LinearToSRGB(rgb), 1.0f);
}

/*
Shader Resources:
	Texture HDR (as SRV)
	Texture SDR (as UAV)
*/
